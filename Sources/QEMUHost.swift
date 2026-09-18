import Darwin
import Foundation

private typealias QEMUInitFn = @convention(c) (
    Int32,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
private typealias QEMUMainLoopFn = @convention(c) () -> Void
private typealias QEMUCleanupFn = @convention(c) () -> Void

/// Loads the QEMU system emulator and runs it in-process.
///
/// The macOS builds of UTM spawn QEMU through XPC. iOS has no such option: an
/// app cannot create a process, so the emulator is linked as a dynamic library
/// and its main loop runs on a thread. This type owns that thread and the
/// console plumbing that goes with it.
final class QEMUHost {
    /// Extra behaviour that only applies to one boot.
    ///
    /// Provisioning needs a machine that the guest can talk to before it has
    /// any configuration of its own: a seed server to reach, and a disk that is
    /// still the size of the downloaded image. Neither belongs in the saved VM
    /// description, so they travel separately.
    struct BootProfile {
        struct Resize {
            /// Block node declared by the drive, not a device name.
            var node: String
            var sizeGiB: Int
        }

        var extraArguments: [String] = []
        var resize: Resize?
    }

    enum HostError: Error, CustomStringConvertible {
        case debuggerNotAttached
        case libraryMissing(String)
        case symbolMissing(String)
        case imageMissing(String)
        case alreadyRunning
        case emulatorBusy
        case blockDevice(String)

        var description: String {
            switch self {
            case .debuggerNotAttached:
                return "JIT is unavailable: attach StikDebug to this app first, then start the VM."
            case .libraryMissing(let p):
                return "QEMU library not found at \(p)"
            case .symbolMissing(let s):
                return "QEMU library is missing symbol \(s)"
            case .imageMissing(let p):
                return "Disk image not found at \(p)"
            case .alreadyRunning:
                return "A virtual machine is already running."
            case .emulatorBusy:
                return "上一台模拟器还没有退出（正在关机或卡住了），等它结束再启动。"
            case .blockDevice(let reason):
                return "无法打开磁盘：\(reason)"
            }
        }
    }

    /// Guest architecture this build hosts.
    let architecture = "aarch64"

    /// Called with decoded console text. Delivered on an arbitrary queue.
    var onConsoleOutput: ((String) -> Void)?
    /// Called with the raw bytes of console output, before any decoding.
    ///
    /// A terminal client needs these: decoding to a string here would corrupt
    /// any escape sequence that straddles a read boundary, and the serial line
    /// is not guaranteed to be valid UTF-8 at all.
    var onConsoleBytes: ((Data) -> Void)?
    /// Called with human-readable status lines from the host, not the guest.
    var onLog: ((String) -> Void)?
    /// Called when the guest stops, with the process exit status.
    var onExit: ((Int32) -> Void)?
    /// qemu_init returned; guest execution is about to begin.
    var onInitialized: (() -> Void)?

    private var serialHostFd: Int32 = -1
    private var serialReadSource: DispatchSourceRead?
    private var qmpHostFd: Int32 = -1
    private var qmpReadSource: DispatchSourceRead?
    private var consoleBytesTotal = 0
    private var loggedConsoleSample = false
    private var qemuThread: Thread?
    private var libraryHandle: UnsafeMutableRawPointer?
    private var isRunning = false
    /// False while a previous emulator thread is still inside QEMU.
    ///
    /// QEMU cannot be initialised twice in one process: the second `qemu_init`
    /// walks over the first one's state and takes the app down with it. So a
    /// start is refused until the previous thread has actually returned, and
    /// stopping means asking the emulator to exit rather than dropping our end
    /// of its console and pretending.
    private var emulatorFinished = true
    private var loggedConsoleRead = false
    private var loggedConsoleWrite = false
    /// The guest's own serial output, kept on disk.
    ///
    /// The frontend draws the machine; this is the text the machine printed.
    /// When a boot stalls before the kernel, that text is the only evidence of
    /// where it stopped, and it has to survive the app being killed.
    private let transcriptQueue = DispatchQueue(label: "com.pocketvm.transcript", qos: .utility)
    private var transcriptBytes = 0

    /// The monitor is one connection. The disk resize at boot, the request that
    /// stops the machine and the periodic screen grabs all travel over it, and
    /// QEMU answers them in order, so two callers reading replies at once would
    /// each take the other's answer.
    private static let monitorLock = NSLock()

    var running: Bool { isRunning }

    // MARK: - Paths

    private var frameworksDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
    }

    private var firmwareDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("qemu", isDirectory: true)
    }

    private func libraryPath(for mode: ExecutionMode) -> String {
        frameworksDirectory
            .appendingPathComponent("\(mode.frameworkName).framework", isDirectory: true)
            .appendingPathComponent(mode.frameworkName, isDirectory: false)
            .path
    }

    private func documents() -> URL {
        VMConfiguration.documentsDirectory
    }

    // MARK: - Lifecycle

    func start(configuration: VMConfiguration, profile: BootProfile = BootProfile(), mode: ExecutionMode) throws {
        guard !isRunning else { throw HostError.alreadyRunning }
        guard emulatorFinished else { throw HostError.emulatorBusy }
        let config = configuration.validated()

        // Never load the code-generating runtime without permission.
        if mode == .jit && !JIT.isDebugged { throw HostError.debuggerNotAttached }
        let libraryPath = libraryPath(for: mode)
        log(JIT.explanation)

        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw HostError.libraryMissing(libraryPath)
        }

        let console = try makeSerialConsole()
        serialHostFd = console.hostFd

        // The monitor is wired up for every boot, not only when the disk has to
        // be grown: it is also the only way to ask the emulator to exit, which
        // is what makes a second start possible at all.
        let qmp: (hostFd: Int32, guestFd: Int32)
        do { qmp = try makeSerialConsole() } catch {
            close(console.hostFd)
            close(console.guestFd)
            serialHostFd = -1
            throw error
        }
        qmpHostFd = qmp.hostFd

        func closeSockets() {
            close(console.hostFd)
            close(console.guestFd)
            close(qmp.hostFd)
            close(qmp.guestFd)
            serialHostFd = -1
            qmpHostFd = -1
        }

        let argv: [String]
        do {
            argv = try buildArguments(
                config: config,
                mode: mode,
                profile: profile,
                qemuSerialFd: console.guestFd,
                qmpFd: qmp.guestFd
            )
        } catch {
            closeSockets()
            throw error
        }

        let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL)
        guard let handle else {
            let message = String(cString: dlerror())
            closeSockets()
            throw HostError.libraryMissing("\(libraryPath): \(message)")
        }
        libraryHandle = handle

        guard
            let initSym = dlsym(handle, "qemu_init"),
            let loopSym = dlsym(handle, "qemu_main_loop"),
            let cleanupSym = dlsym(handle, "qemu_cleanup")
        else {
            dlclose(handle)
            libraryHandle = nil
            closeSockets()
            throw HostError.symbolMissing("qemu_init / qemu_main_loop / qemu_cleanup")
        }

        let qemuInit = unsafeBitCast(initSym, to: QEMUInitFn.self)
        let qemuMainLoop = unsafeBitCast(loopSym, to: QEMUMainLoopFn.self)
        let qemuCleanup = unsafeBitCast(cleanupSym, to: QEMUCleanupFn.self)

        argv.forEach { log("qemu \($0)") }
        startReadingConsole(fd: console.hostFd)

        isRunning = true
        let thread = Thread { [weak self] in
            let status = QEMUHost.runQEMU(
                argv: argv,
                onInitialized: { [weak self] in
                    DispatchQueue.main.async { [weak self] in self?.onInitialized?() }
                    guard let self, self.qmpHostFd >= 0 else { return }
                    QEMUHost.growDisk(fd: self.qmpHostFd, resize: profile.resize) { line in
                        DispatchQueue.main.async { self.log(line) }
                    }
                },
                qemuInit: qemuInit,
                qemuMainLoop: qemuMainLoop,
                qemuCleanup: qemuCleanup
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("qemu exited with status \(status)")
                self.emulatorFinished = true
                self.teardown()
                self.onExit?(status)
            }
        }
        thread.name = "qemu-system-\(architecture)"
        thread.stackSize = 4 << 20
        qemuThread = thread
        emulatorFinished = false
        thread.start()
    }

    /// Asks the guest to shut down through ACPI: systemd inside the guest does
    /// the rest, and QEMU exits its main loop when the machine goes down.
    func requestPowerDown() {
        guard isRunning else { return }
        log("asking the guest to power down")
        QEMUHost.monitorLock.lock()
        defer { QEMUHost.monitorLock.unlock() }
        QEMUHost.sendMonitor(fd: qmpHostFd, command: "{\"execute\":\"system_powerdown\"}\n")
    }

    /// Asks the emulator itself to exit. This is the blunt one: the guest gets no
    /// chance to unmount anything, which is why it is only used after a power
    /// down request has been ignored.
    func requestQuit() {
        guard isRunning else { return }
        log("asking the emulator to quit")
        QEMUHost.monitorLock.lock()
        defer { QEMUHost.monitorLock.unlock() }
        QEMUHost.sendMonitor(fd: qmpHostFd, command: "{\"execute\":\"quit\"}\n")
    }

    // MARK: - Console transcript

    private var transcriptPath: String {
        documents().appendingPathComponent("console.log").path
    }

    /// Appends what the guest said. Rotated at half a megabyte: a boot that
    /// works is not interesting, the one that hangs is.
    private func appendTranscript(_ data: Data) {
        transcriptQueue.async { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: self.transcriptPath)
            if self.transcriptBytes > 512 * 1024 {
                try? Data().write(to: url)
                self.transcriptBytes = 0
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            self.transcriptBytes += data.count
        }
    }

    private func teardown() {
        isRunning = false
        serialReadSource?.cancel()
        serialReadSource = nil
        if serialHostFd >= 0 {
            close(serialHostFd)
            serialHostFd = -1
        }
        qmpReadSource?.cancel()
        qmpReadSource = nil
        if qmpHostFd >= 0 {
            close(qmpHostFd)
            qmpHostFd = -1
        }
        if let handle = libraryHandle {
            // Deliberately not dlclose()d. QEMU does not tear down cleanly
            // enough for a second load in the same process, and leaving the
            // mapping in place is what UTM settled on for the same reason.
            _ = handle
        }
        qemuThread = nil
    }

    // MARK: - Console

    /// QEMU takes one end of a socket pair as its character device; the app
    /// keeps the other and presents it. This keeps input and output
    /// bidirectional without touching the filesystem.
    private func makeSerialConsole() throws -> (hostFd: Int32, guestFd: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.ENFILE)
        }
        var noSignal: Int32 = 1
        for fd in fds {
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        }
        return (fds[1], fds[0])
    }

    func writeToConsole(_ text: String) {
        guard serialHostFd >= 0, let data = text.data(using: .utf8) else { return }
        writeToConsole(data)
    }

    /// Write raw bytes to the guest's serial line, bypassing any encoding.
    func writeToConsole(_ data: Data) {
        guard serialHostFd >= 0, !data.isEmpty else { return }
        if !loggedConsoleWrite {
            loggedConsoleWrite = true
            log("console: first write of \(data.count) bytes to the guest")
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(serialHostFd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    log("console: write failed after \(offset)/\(raw.count) bytes, errno \(errno)")
                    break
                }
            }
        }
    }

    private func startReadingConsole(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                let code = errno
                // EAGAIN here is the descriptor's own business: the source will
                // fire again when there is something to read.
                if code != EAGAIN { self.log("console: read failed, errno \(code)") }
                return
            }
            if count == 0 {
                // QEMU closed its end of the line. Without this the panel just
                // sits there and looks like the guest had nothing to say.
                self.log("console: the guest's end of the line closed")
                source.cancel()
                return
            }
            if !loggedConsoleRead {
                loggedConsoleRead = true
                log("console: first read of \(count) bytes from the guest")
            }
            self.noteConsoleRead(count, bytes: buffer)
            let slice = buffer[0..<count]
            self.appendTranscript(Data(slice))
            self.onConsoleBytes?(Data(slice))
            let text = String(decoding: slice, as: UTF8.self)
            self.onConsoleOutput?(text)
        }
        source.resume()
        serialReadSource = source
    }

    /// How much the guest has actually said, and what it opened with.
    ///
    /// "The terminal is empty" has two very different causes — the bytes never
    /// arrived, or they arrived and were not drawn — and a counter is the only
    /// way to tell them apart after the fact.
    private func noteConsoleRead(_ count: Int, bytes: [UInt8]) {
        let previous = consoleBytesTotal
        consoleBytesTotal += count
        for threshold in [1024, 65536, 1048576]
        where consoleBytesTotal >= threshold && previous < threshold {
            log("console: \(threshold) bytes received from the guest")
        }
        if !loggedConsoleSample {
            loggedConsoleSample = true
            log("console: first bytes \(QEMUHost.sample(of: bytes, count: count))")
        }
    }

    /// The opening of the guest's output, with the bytes that would eat the log
    /// spelled out, so a stream that stops mid-sequence is visible as such.
    private static func sample(of bytes: [UInt8], count: Int) -> String {
        var text = ""
        for byte in bytes[0..<min(count, 120)] {
            switch byte {
            case 0x1B: text += "^["
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x20...0x7E: text.append(Character(UnicodeScalar(byte)))
            default: text += "."
            }
        }
        return text
    }

    // MARK: - Arguments

    private func resolve(_ relative: String) -> URL {
        let url = URL(fileURLWithPath: relative)
        return url.isFileURL && relative.hasPrefix("/")
            ? url
            : documents().appendingPathComponent(relative)
    }

    private func requireFile(_ relative: String) throws -> String {
        let url = resolve(relative)
        let documentsURL = documents().resolvingSymlinksInPath().standardizedFileURL
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix = documentsURL.path.hasSuffix("/") ? documentsURL.path : documentsURL.path + "/"
        var isDirectory = ObjCBool(false)
        guard candidate.path == documentsURL.path || candidate.path.hasPrefix(prefix),
              FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw HostError.imageMissing(url.path)
        }
        return candidate.path
    }

    private func buildArguments(
        config: VMConfiguration,
        mode: ExecutionMode,
        profile: BootProfile,
        qemuSerialFd: Int32,
        qmpFd: Int32
    ) throws -> [String] {
        var args: [String] = ["qemu-system-\(architecture)"]

        // `virtualization=on` matches what UTM configures on this device, and
        // the guest has no way to tell whether those extensions are hardware.
        args += ["-machine", "virt,virtualization=on"]
        args += ["-cpu", "cortex-a72"]
        args += ["-smp", String(config.cpuCount)]
        args += ["-m", String(config.memoryMiB)]

        args += ["-accel", mode.accelerator(cacheMiB: config.jitCacheMiB, multicore: config.forceMulticore)]

        // Firmware and future ACPI tables live in the bundle.
        args += ["-L", firmwareDirectory.path]
        // No window backend. There is nothing to draw to: the guest's own
        // system has no graphics driver, so a display device would only add a
        // PCI slot and a boot entry that could stop resolving.
        args += ["-display", "none"]

        // Console over the socket pair created above.
        args += ["-chardev", "socket,id=term0,fd=\(qemuSerialFd)"]
        args += ["-serial", "chardev:term0"]

        // A control-mode monitor, so the disk can be grown to the size the
        // image was asked to have before the guest's kernel sees it.
        if qmpFd >= 0 {
            args += ["-chardev", "socket,id=qmp0,fd=\(qmpFd)"]
            args += ["-mon", "chardev=qmp0,mode=control"]
        }

        args += profile.extraArguments

        switch config.boot.mode {
        case .direct:
            guard let kernel = config.boot.kernel else {
                throw VMConfigurationError.missingFile("boot.kernel")
            }
            args += ["-kernel", try requireFile(kernel)]
            if let initrd = config.boot.initrd {
                args += ["-initrd", try requireFile(initrd)]
            }
            let cmdline = config.boot.cmdline ?? "console=ttyAMA0 root=/dev/vda2"
            args += ["-append", cmdline]

        case .uefi:
            // Unit 0 is the firmware, unit 1 the variable store. UTM spells out
            // the units and turns file locking off, and QEMU on iOS behaves the
            // same way, so the arguments match what is known to boot here.
            args += [
                "-drive",
                "if=pflash,format=raw,unit=0,readonly=on,file.locking=off,file.filename=\(firmwareDirectory.appendingPathComponent("edk2-aarch64-code.fd").path)",
            ]
        }

        // The firmware occupies unit 0, so configured pflash drives follow it.
        var pflashUnit = 1
        for drive in config.drives {
            let path = try requireFile(drive.path)
            switch drive.interface {
            case .pflash:
                args += [
                    "-drive",
                    "if=pflash,format=raw,unit=\(pflashUnit),file.locking=off,file.filename=\(path)",
                ]
                pflashUnit += 1
            case .virtio:
                args += try blockArguments(for: drive, path: path)
            case .usb:
                let format = drive.format ?? (path.hasSuffix(".qcow2") ? "qcow2" : "raw")
                args += ["-drive", "if=none,id=usbdrive,format=\(format),file=\(path)"]
                args += ["-device", "usb-storage,drive=usbdrive"]
            }
        }

        if config.network.enabled {
            var netdev = "user,id=net0"
            if let forward = config.sshForward { netdev += ",hostfwd=\(forward)" }
            for forward in config.network.portForwards {
                netdev += ",hostfwd=\(forward.protocolName)::\(forward.hostPort)-:\(forward.guestPort)"
            }
            args += ["-netdev", netdev]
            args += ["-device", "virtio-net-pci,netdev=net0"]
        }

        return args
    }

    /// Arguments for one virtio disk.
    ///
    /// A drive that carries a node name is declared as explicit block nodes
    /// instead of with `-drive`, because `-drive` cannot name a node and the
    /// monitor addresses nodes by name. Everything else keeps the short form.
    private func blockArguments(for drive: VMConfiguration.Drive, path: String) throws -> [String] {
        let format = drive.format ?? (path.hasSuffix(".qcow2") ? "qcow2" : "raw")
        guard let node = drive.nodeName else {
            var spec = "if=virtio,format=\(format),file=\(path)"
            if drive.readOnly { spec += ",readonly=on" }
            return ["-drive", spec]
        }
        let readOnly = drive.readOnly ? ",read-only=on" : ""
        return [
            "-blockdev", "driver=file,filename=\(path),node-name=\(node)-file,aio=threads,locking=off\(readOnly)",
            "-blockdev", "driver=\(format),file=\(node)-file,node-name=\(node)\(readOnly)",
            "-device", "virtio-blk-pci,drive=\(node),id=\(node)-dev",
        ]
    }

    // MARK: - Emulator entry

    private static func runQEMU(
        argv: [String],
        onInitialized: (() -> Void)? = nil,
        qemuInit: QEMUInitFn,
        qemuMainLoop: QEMUMainLoopFn,
        qemuCleanup: QEMUCleanupFn
    ) -> Int32 {
        // QEMU mutates its argv, so hand it memory it owns.
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }

        let environment = ProcessInfo.processInfo.environment
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { for pointer in cEnv where pointer != nil { free(pointer) } }

        let status = cArgs.withUnsafeMutableBufferPointer { argBuffer -> Int32 in
            cEnv.withUnsafeMutableBufferPointer { envBuffer -> Int32 in
                let initResult = qemuInit(Int32(argv.count), argBuffer.baseAddress, envBuffer.baseAddress)
                if initResult != 0 { return initResult }
                // Anything that has to happen between "the machine exists" and
                // "the guest runs" belongs here.
                onInitialized?()
                qemuMainLoop()
                qemuCleanup()
                return 0
            }
        }
        return status
    }

    // MARK: - Monitor

    /// Grows a block node through the emulator's own monitor.
    ///
    /// The downloaded image is a small qcow2 whose declared size is whatever
    /// Debian built it with. A cloud image fills that size on first boot, so the
    /// resize has to happen before the guest's kernel reads the partition table.
    /// Doing it through the monitor avoids shipping `qemu-img` — a second
    /// emulator binary — for this one operation.
    ///
    /// Failures are not fatal. If the resize does not land in time, the guest's
    /// own provisioning script grows the filesystem on the next boot instead.
    /// Brings the monitor up: reads its greeting, negotiates capabilities, and
    /// grows the disk when this boot asked for it.
    ///
    /// Capabilities matter beyond the resize — the command that stops the
    /// machine is refused until they are negotiated, and stopping through the
    /// monitor is the only way a later start can work at all.
    ///
    /// Failures are logged rather than thrown: a resize that does not land is
    /// retried by the guest's own provisioning script, and a machine that cannot
    /// be asked to stop is left running instead of being crashed by a second
    /// `qemu_init`.
    private static func growDisk(
        fd: Int32,
        resize: BootProfile.Resize?,
        log: @escaping (String) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            // The greeting and the capability negotiation are a conversation on
            // the one monitor, so they are held under the same lock as every
            // later command.
            monitorLock.lock()
            defer { monitorLock.unlock() }
            guard let greeting = readMonitorLine(fd: fd, timeout: 10) else {
                log("qmp: 模拟器没有问候")
                return
            }
            log("qmp: \(greeting)")

            sendMonitor(fd: fd, command: "{\"execute\":\"qmp_capabilities\"}\n")
            if let reply = readMonitorLine(fd: fd, timeout: 5) { log("qmp: \(reply)") }

            guard let resize else { return }
            let bytes = Int64(resize.sizeGiB) * 1_073_741_824
            // `node-name` addresses the block node the drive declared. The older
            // `device` spelling only finds a name that a BlockBackend owns, which
            // a `-blockdev` node is not.
            sendMonitor(
                fd: fd,
                command: "{\"execute\":\"block_resize\",\"arguments\":{\"node-name\":\"\(resize.node)\",\"size\":\(bytes)}}\n"
            )
            if let reply = readMonitorLine(fd: fd, timeout: 30) { log("qmp: \(reply)") }
        }
    }

    /// One complete line from the monitor, or nil once the timeout passes.
    private static func readMonitorLine(fd: Int32, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            if let chunk = readAvailable(fd: fd, timeoutMilliseconds: 400) {
                buffer.append(chunk)
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// One monitor command. The monitor is a text protocol on a socket pair the
    /// app owns, so a write that fails is a missing stop, not a crash.
    static func sendMonitor(fd: Int32, command: String) {
        guard fd >= 0 else { return }
        writeAll(fd: fd, data: Data(command.utf8))
    }

    private static func readAvailable(fd: Int32, timeoutMilliseconds: Int32) -> Data? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        onLog?(message)
    }
}
