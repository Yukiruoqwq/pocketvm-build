import Foundation

/// Persisted record of the one-time guest setup.
///
/// Kept beside the image rather than inside `pocketvm.json` so that editing VM
/// settings from the frontend can never accidentally re-trigger provisioning or
/// forget that it already happened.
struct ProvisionState: Codable {
    var imageIdentifier: String = GuestImage.debianCloudARM64.identifier
    var completed: Bool = false
    var completedAt: Date?
    /// The qcow2 has been grown to the requested capacity.
    var capacityApplied: Bool = false
    var password: String = ProvisionState.makePassword()
    var instanceID: String = UUID().uuidString.lowercased()

    static var url: URL {
        VMConfiguration.documentsDirectory.appendingPathComponent("provision.json")
    }

    static func load() -> ProvisionState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ProvisionState.self, from: data) else {
            return ProvisionState()
        }
        return state
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: ProvisionState.url, options: .atomic)
    }

    /// Six digits: the login is for a serial console the device owner is already
    /// holding, and a password nobody can dictate over a cable is worse than a
    /// short one that is displayed in the app.
    static func makePassword() -> String {
        String(format: "%06d", Int.random(in: 100000...999999))
    }
}

/// Drives the first boot of the guest.
///
/// The app ships no disk image, so the first run has to fetch one, tell
/// cloud-init what to do with it, and then watch the guest work. All of that is
/// reported to the frontend as a stage, and the guest reports its own progress
/// on the serial console, which is the same stream the terminal shows.
@MainActor
final class Provisioner: ObservableObject {
    enum Stage: Equatable {
        case idle
        case downloading(Double)
        case verifying(Double)
        case preparing
        case booting
        /// A progress line echoed by the guest while it installs packages.
        case installing(String)
        case ready
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .verifying, .preparing, .booting, .installing: return true
            case .idle, .ready, .failed: return false
            }
        }

        var description: String {
            switch self {
            case .idle: return "未准备"
            case .downloading(let fraction): return "下载镜像 \(Int(fraction * 100))%"
            case .verifying(let fraction): return "校验镜像 \(Int(fraction * 100))%"
            case .preparing: return "准备启动参数"
            case .booting: return "首次启动，等待客户机"
            case .installing(let line): return line
            case .ready: return "准备完成"
            case .failed(let reason): return "失败：\(reason)"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var state: ProvisionState

    let image = GuestImage.debianCloudARM64
    private let store = GuestImageStore()
    private var server: SeedServer?
    private var lineBuffer = ""

    /// Set when the guest reports that it finished; the caller uses it to drop
    /// the seed arguments from the next boot.
    var onFinished: ((ProvisionState) -> Void)?
    var onLog: ((String) -> Void)?

    init() {
        state = ProvisionState.load()
        if state.completed {
            stage = .ready
        }
        if state.imageIdentifier != image.identifier {
            // A build that points at a different image has nothing to say about
            // the previous one's completion.
            state.completed = false
            state.imageIdentifier = image.identifier
            stage = .idle
        }
    }

    var isProvisioned: Bool { state.completed }

    /// The port the guest reports to. Fixed rather than chosen per boot, because
    /// the guest's boot-time reporter has to know it without being told — that
    /// is the point of having a channel at all.
    static let helperPort: UInt16 = 8474

    /// Called with the body of every POST from the guest. This, not the console,
    /// is how the guest is heard from.
    var onGuestReport: ((String, Data) -> Void)?

    /// Where the guest reaches the host's own helper files.
    ///
    /// QEMU's user-mode networking makes `10.0.2.2` an alias for the host's
    /// loopback, so the listener never has to leave the device or ask for the
    /// local-network permission. The files themselves ship inside the app: this
    /// is the only way to put a helper into a guest that was installed by an
    /// earlier build, without asking the user to run anything by hand.
    var helperBaseURL: String? {
        guard let server, server.port != 0 else { return nil }
        return "http://10.0.2.2:\(server.port)"
    }

    /// Fetches whatever is missing and returns the boot profile for first boot.
    func prepare() async throws -> (configuration: VMConfiguration, profile: QEMUHost.BootProfile) {
        if !state.completed {
            if !FileManager.default.fileExists(atPath: image.localURL.path) {
                _ = try await ensureImage()
            } else {
                stage = .verifying(0)
                do {
                    try await verifyExisting()
                } catch {
                    stage = .downloading(0)
                    _ = try await ensureImage()
                }
            }
        }

        stage = .preparing
        excludeFromBackup()
        try installUEFIVariables()
        var configuration = try VMConfiguration.loadOrCreateDefault()
        configuration.name = "Debian 13 · aarch64"
        configuration.boot = bootConfiguration()
        configuration.drives = defaultDrives(existing: configuration, boot: configuration.boot)
        configuration = configuration.validated()
        try configuration.write()

        // The helper server runs on every boot — the seed only on the first —
        // because the frontend asks the guest for its model list long after
        // provisioning is done.
        server?.stop()
        server = try startHelperServer()
        let profile = try makeBootProfile()
        stage = .booting
        return (configuration, profile)
    }

    /// Feeds one line of guest console output through the state machine.
    func ingest(consoleLine line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let message = trimmed.range(of: "POCKETVM:") {
            let text = String(trimmed[message.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                stage = .installing(text)
                onLog?("guest: \(text)")
            }
            return
        }
        if trimmed.contains("POCKETVM_READY") {
            markProvisioned()
            return
        }
        if trimmed.contains("POCKETVM_FAILED") {
            stage = .failed("客户机报告安装失败，可在终端里查看 /var/log/pocketvm-provision.log")
            return
        }
    }

    func markProvisioned() {
        guard !state.completed else { return }
        state.completed = true
        // The disk has been carrying its final size since this boot, so the
        // resize does not need to be attempted again.
        state.capacityApplied = true
        state.completedAt = Date()
        state.write()
        stage = .ready
        onLog?("guest reported provisioning complete")
        onFinished?(state)
    }

    func reset() {
        server?.stop()
        server = nil
        state = ProvisionState()
        state.write()
        stage = .idle
    }

    // MARK: - Image

    private func ensureImage() async throws -> URL {
        let image = self.image
        return try await withCheckedThrowingContinuation { continuation in
            store.ensure(image, onEvent: { [weak self] event in
                switch event {
                case .downloading(let fraction): self?.stage = .downloading(fraction)
                case .verifying(let fraction): self?.stage = .verifying(fraction)
                }
            }, onFinish: { result in
                continuation.resume(with: result)
            })
        }
    }

    private func verifyExisting() async throws {
        let url = image.localURL
        let expected = image.sha512
        let digest = try await Task.detached(priority: .utility) { [weak self] () -> String in
            try GuestImageStore.sha512Hex(of: url) { fraction in
                Task { @MainActor in self?.stage = .verifying(fraction) }
            }
        }.value
        guard digest == expected else {
            throw GuestImageError.checksumMismatch(expected: expected, actual: digest)
        }
    }

    // MARK: - Firmware

    /// The guest disk is tens of gigabytes of sparse file that iOS would happily
    /// try to back up. Nothing in it is worth backing up: it can be rebuilt from
    /// the image, and the image can be re-downloaded.
    private func excludeFromBackup() {
        var url = GuestImage.imagesDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// UTM uses the ARM variable-store template for aarch64 as well; the
    /// aarch64 image ships code only. The guest writes boot entries into this
    /// file, so it lives in Documents next to the disk.
    ///
    /// The template is 321 KB while the flash device it backs is 64 MiB. QEMU's
    /// own builds ship the variable store already padded to that size, and newer
    /// emulators refuse a backend smaller than the device outright, so the file
    /// is padded here rather than relying on the emulator to do it.
    private func installUEFIVariables() throws {
        let destination = VMConfiguration.documentsDirectory.appendingPathComponent("efi_vars.fd")
        if FileManager.default.fileExists(atPath: destination.path) { return }
        guard let template = Bundle.main.url(forResource: "edk2-arm-vars", withExtension: "fd", subdirectory: "qemu") else {
            throw VMConfigurationError.missingFile("qemu/edk2-arm-vars.fd")
        }
        let flashSize = 64 * 1024 * 1024
        var contents = try Data(contentsOf: template)
        if contents.count < flashSize {
            contents.append(Data(repeating: 0xFF, count: flashSize - contents.count))
        }
        try contents.write(to: destination, options: .atomic)
    }

    /// How this boot starts the guest.
    ///
    /// The kernel and the initrd are the image's own, copied out of its root
    /// filesystem once. When they are there, the machine boots them directly:
    /// the firmware and the boot loader never run, so there is nothing that can
    /// stop at a menu and wait for a key that a tablet cannot press, and the
    /// console starts printing within a second instead of twenty. Without them
    /// the machine still boots the way it always did.
    private func bootConfiguration() -> VMConfiguration.Boot {
        let documents = VMConfiguration.documentsDirectory
        let direct = image.directBoot
        let kernel = documents.appendingPathComponent(direct.kernel)
        let initrd = documents.appendingPathComponent(direct.initrd)
        guard FileManager.default.fileExists(atPath: kernel.path),
              FileManager.default.fileExists(atPath: initrd.path) else {
            return VMConfiguration.Boot(mode: .uefi)
        }
        onLog?("booting the guest's own kernel directly")
        return VMConfiguration.Boot(
            mode: .direct,
            kernel: direct.kernel,
            initrd: direct.initrd,
            cmdline: direct.cmdline
        )
    }

    private func defaultDrives(
        existing: VMConfiguration,
        boot: VMConfiguration.Boot
    ) -> [VMConfiguration.Drive] {
        var drives: [VMConfiguration.Drive] = []
        // The variable store belongs to the firmware, and a pflash device with
        // no firmware in front of it is a device QEMU would have to invent a
        // pairing for.
        if boot.mode != .direct {
            drives.append(
                VMConfiguration.Drive(
                    path: "efi_vars.fd",
                    interface: .pflash,
                    readOnly: false
                )
            )
        }
        drives.append(
            VMConfiguration.Drive(
                path: "Images/\(image.fileName)",
                interface: .virtio,
                readOnly: false,
                format: "qcow2",
                nodeName: "root"
            )
        )
        // Keep drives the user added beyond the two we manage.
        for drive in existing.drives where drive.interface != .pflash && drive.nodeName != "root" {
            if !drives.contains(where: { $0.path == drive.path }) { drives.append(drive) }
        }
        return drives
    }

    // MARK: - Seed

    /// Starts the listener the guest fetches both cloud-init's seed and the
    /// helper scripts from.
    private func startHelperServer() throws -> SeedServer {
        var resources: [String: SeedServer.Resource] = [:]
        for name in [
            "pocketvm-app.mjs", "pocketvm-report.sh", "pocketvm-boot.sh",
            "pocketvm-agent.sh", "setup-proxy.sh",
        ] {
            guard let text = Self.bundledGuestFile(name) else {
                onLog?("helper \(name) is missing from the app bundle")
                continue
            }
            resources["/\(name)"] = .text(text)
        }
        // The proxy is the owner's own subscription, so it lives in
        // Documents/proxy.txt on the device rather than in the build: this
        // repository is public, and a subscription link is a credential.
        if let subscription = proxySubscription() {
            resources["/proxy-url.txt"] = .text(subscription + "\n")
        }
        // A copy of the proxy's own binary, if one was left on the device. The
        // guest cannot always reach GitHub — and when it can, it is often slow
        // enough that a 20 MB download looks like a hang. The app's helper
        // server is on the emulated network, so this is instant.
        let binary = VMConfiguration.documentsDirectory.appendingPathComponent("mihomo.gz")
        if let data = try? Data(contentsOf: binary), !data.isEmpty {
            resources["/mihomo.gz"] = SeedServer.Resource(contentType: "application/gzip", body: data)
        }
        // Offered on every boot, not only the first.
        //
        // cloud-init treats `runcmd` as once per instance and `bootcmd` as once
        // per boot, and the instance id does not change, so a guest that was
        // installed by an older build still picks up the console setup and the
        // current helpers as soon as its next start finds this datastore. That
        // is the only way to change anything inside a guest that is already
        // installed: there is no shell on the device to type into yet.
        resources["/meta-data"] = .yaml(metadata())
        resources["/user-data"] = .yaml(userData())
        resources["/vendor-data"] = .text("#cloud-config\n")

        // The fixed port is what a guest installed by this build already knows;
        // if something else on the device holds it, an ephemeral one still lets
        // the console fallback do the work.
        if let server = try? SeedServer(preferredPort: Self.helperPort) {
            configure(server)
            do {
                try server.start(resources: resources)
                return server
            } catch {
                onLog?("helper port \(Self.helperPort) is taken: \(error)")
            }
        }
        let server = try SeedServer(preferredPort: 0)
        configure(server)
        try server.start(resources: resources)
        return server
    }

    private func configure(_ server: SeedServer) {
        server.onLog = { [weak self] line in self?.onLog?("helper: \(line)") }
        server.onRequest = { [weak self] line in self?.onLog?("guest: \(line)") }
        // The report is the guest talking, so it is logged as such rather than
        // as a seed fetch.
        server.onPost = { [weak self] path, body in
            guard let self else { return }
            // The agent's answers are this side's business; everything else the
            // guest posts is a report for the app.
            if path == "/result" {
                self.handleCommandResult(body)
                return
            }
            self.onGuestReport?(path, body)
        }
        server.onUpload = { [weak self] name, body in self?.store(upload: name, body: body) }
        server.onDynamicResource = { [weak self] path in self?.dynamicResource(path) }
    }

    // MARK: - Commands

    /// The command waiting to be collected, and the answers still expected.
    private var queuedCommand: (id: String, script: String)?
    private var commandCallbacks: [String: (String) -> Void] = [:]
    private var commandCounter = 0
    /// When the agent last came asking for work. A guest installed by an older
    /// build has no agent, and the caller needs to know which of the two
    /// channels to use.
    private var agentLastSeen = Date.distantPast

    var agentIsLive: Bool { Date().timeIntervalSince(agentLastSeen) < 12 }

    /// Asks the guest to run a script, and hands the output to `callback`.
    ///
    /// One at a time: the queue holds a single command so that an answer can
    /// never be matched to the wrong question.
    func runInGuest(_ script: String, callback: @escaping (String) -> Void) {
        commandCounter += 1
        let id = String(commandCounter)
        // A command nobody collected is replaced rather than queued behind: the
        // newest question is the one whose answer is still wanted.
        if let old = queuedCommand { commandCallbacks.removeValue(forKey: old.id) }
        queuedCommand = (id: id, script: script)
        commandCallbacks[id] = callback
        onLog?("queued a command for the guest (#\(commandCounter))")
    }

    /// `/command`: the guest polling for work.
    private func dynamicResource(_ path: String) -> SeedServer.Resource? {
        guard path == "/command" else { return nil }
        agentLastSeen = Date()
        guard let queued = queuedCommand else { return .text("") }
        queuedCommand = nil
        return .text("\(queued.id)\n\(queued.script)")
    }

    /// The guest's answer to a queued command.
    private func handleCommandResult(_ body: Data) {
        guard let text = String(data: body, encoding: .utf8) else { return }
        let split = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let id = split.first.map(String.init) else { return }
        let output = split.count > 1 ? String(split[1]) : ""
        guard let callback = commandCallbacks.removeValue(forKey: id) else { return }
        onLog?("guest answered command #\(id) with \(output.count) bytes")
        callback(output)
    }

    /// The guest handing over the two files that let the next start boot its own
    /// kernel.
    ///
    /// Nothing else can produce them: they are the image's own, they have to be
    /// the running kernel's version to match `/lib/modules`, and a fresh install
    /// has nobody on the cable to copy them across. A half-written file is worse
    /// than no file — it would be booted — so the write is atomic and a body
    /// that is obviously short is refused.
    private func store(upload name: String, body: Data) {
        let destination: String
        switch name {
        case "vmlinuz": destination = image.directBoot.kernel
        case "initrd": destination = image.directBoot.initrd
        default:
            onLog?("guest uploaded an unknown file: \(name)")
            return
        }
        guard body.count > 1 << 20 else {
            onLog?("guest's \(name) is too small to be real: \(body.count) bytes")
            return
        }
        let url = VMConfiguration.documentsDirectory.appendingPathComponent(destination)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try body.write(to: url, options: .atomic)
            onLog?("guest handed over \(destination): \(body.count) bytes")
        } catch {
            onLog?("could not keep \(destination): \(error)")
        }
    }

    private static func bundledGuestFile(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "guest") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The subscription URL, if one was put in Documents/proxy.txt.
    ///
    /// Served as a separate file rather than baked into the script, so that
    /// what the guest runs is always the version that shipped with the app.
    private func proxySubscription() -> String? {
        let file = VMConfiguration.documentsDirectory.appendingPathComponent("proxy.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("http") }
        guard let line, !line.isEmpty else { return nil }
        onLog?("代理订阅已配置")
        return line
    }

    private func makeBootProfile() throws -> QEMUHost.BootProfile {
        var profile = QEMUHost.BootProfile()
        if let server {
            profile.extraArguments = [
                // cloud-init reads the NoCloud data source URL from the SMBIOS
                // serial number; SLIRP resolves 10.0.2.2 to the host loopback
                // where the seed server is listening.
                "-smbios", "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:\(server.port)/",
            ]
        }
        if !state.capacityApplied {
            profile.resize = QEMUHost.BootProfile.Resize(node: "root", sizeGiB: image.capacityGiB)
        }
        return profile
    }

    private func metadata() -> String {
        """
        instance-id: \(state.instanceID)
        local-hostname: pocketvm
        """
    }

    /// cloud-init configuration for the first boot.
    ///
    /// The guest is expected to come up talking to its own serial port: that is
    /// the only console the app has, so both the login prompt and the progress
    /// reports are written to it explicitly rather than being left to whatever
    /// the distribution decides a console is.
    private func userData() -> String {
        """
        #cloud-config
        hostname: pocketvm
        manage_etc_hosts: true
        ssh_pwauth: true
        users:
          - name: codex
            gecos: Codex
            groups: [adm, sudo, dialout]
            shell: /bin/bash
            sudo: "ALL=(ALL) NOPASSWD:ALL"
        # The password is set here rather than on the user because cloud-init's
        # user schema rejects the plain-text field, and because this module runs
        # after the account is created: whichever order the two take, the hash
        # written here is the one that ends up in the shadow file.
        chpasswd:
          expire: false
          users:
            - name: codex
              # Quoted: six digits without quotes are an integer to the YAML
              # parser, and cloud-init's schema wants a string.
              password: "\(state.password)"
              type: text
        # Runs on every boot, unlike everything below it. A guest that was
        # configured by an older build has no serial console and no current
        # helpers, and this is the only channel that can fix that without
        # somebody typing into the machine first.
        bootcmd:
          - [ bash, -c, "curl -fsS -m 60 http://10.0.2.2:\(Self.helperPort)/pocketvm-boot.sh -o /run/pocketvm-boot.sh && POCKETVM_BASE=http://10.0.2.2:\(Self.helperPort) bash /run/pocketvm-boot.sh || true" ]
        write_files:
          - path: /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf
            permissions: '0644'
            content: |
              [Service]
              ExecStart=
              ExecStart=-/sbin/agetty --autologin codex --keep-baud 115200,38400,9600 %I $TERM
          - path: /usr/local/sbin/pocketvm-provision.sh
            permissions: '0755'
            content: |
        \(indent(provisionScript(), spaces: 6))
          # /usr/local/bin, not /usr/local/sbin: the console logs in as `codex`,
          # and a normal user's PATH does not include the sbin directories. The
          # app types this command at that shell, so it has to be findable
          # without one.
          - path: /usr/local/bin/pocketvm-auth
            permissions: '0755'
            content: |
        \(indent(authScript(), spaces: 6))
          # Announcing readiness from inside the guest is what lets the frontend
          # come forward on its own instead of being typed at. It is enabled
          # rather than started here: on this first boot the CLI does not exist
          # yet, and the provisioning script reports the same thing its own way.
          - path: /etc/systemd/system/pocketvm-ready.service
            permissions: '0644'
            content: |
              [Unit]
              Description=PocketVM readiness marker
              After=multi-user.target

              [Service]
              Type=oneshot
              RemainAfterExit=yes
              ExecStart=/bin/sh -c 'command -v codex >/dev/null 2>&1 && echo POCKETVM_CODEX_READY > /dev/ttyAMA0 || true'

              [Install]
              WantedBy=multi-user.target
        runcmd:
          - systemctl daemon-reload
          - systemctl enable --now serial-getty@ttyAMA0.service
          - systemctl enable pocketvm-ready.service
          - /usr/local/sbin/pocketvm-provision.sh
        """
    }

    /// The guest side of the sign-in flow.
    ///
    /// The host app is the only terminal the user has, so the login has to run
    /// in the background with its output on disk, and the state has to come back
    /// as a couple of fixed lines rather than as a redrawn TUI.
    private func authScript() -> String {
        """
        #!/bin/bash
        # Written by PocketVM. Prints a fixed vocabulary the host parses.
        LOG=/tmp/pocketvm-login.log

        if [ "${1:-status}" = "start" ]; then
          rm -f "$LOG"
          nohup codex login --device-auth >"$LOG" 2>&1 </dev/null &
          sleep 2
        fi

        if codex login status 2>/dev/null | grep -qi "not logged in"; then
          echo POCKETVM_AUTH_STATE not_logged_in
        elif codex login status 2>/dev/null | grep -qi "logged in"; then
          echo POCKETVM_AUTH_STATE logged_in
        else
          echo POCKETVM_AUTH_STATE unknown
        fi

        if [ -s "$LOG" ]; then
          tail -n 30 "$LOG" | tr -d '\\r'
        fi
        """
    }

    /// Runs inside the guest on first boot.
    ///
    /// Every step is emulated aarch64, so the script is deliberately small and
    /// keeps its noisy output in a log file while sending one readable line per
    /// step to the serial console for the app to display.
    private func provisionScript() -> String {
        """
        #!/bin/bash
        # Written by PocketVM. Safe to re-run: every step is idempotent.
        set -u
        TTY=/dev/ttyAMA0
        LOG=/var/log/pocketvm-provision.log
        say() { printf 'POCKETVM: %s\\n' "$*" > "$TTY" 2>/dev/null || true; }

        # The host grows the virtual disk while this boot is already starting,
        # which can land after the kernel first looked at it. Running this twice,
        # with several minutes of package installation in between, means the
        # second pass sees the final size whatever the timing was.
        grow() {
          ROOTDEV="$(findmnt -no SOURCE /)"
          PART="$(printf '%s' "$ROOTDEV" | sed -n 's/.*[^0-9]\\([0-9][0-9]*\\)$/\\1/p')"
          DISK="$(printf '%s' "$ROOTDEV" | sed -n 's/\\(.*[^0-9]\\)[0-9][0-9]*$/\\1/p')"
          if [ -n "$PART" ] && [ -n "$DISK" ] && [ "$PART" != "$DISK" ]; then
            partprobe "$DISK" >/dev/null 2>&1 || true
            growpart "$DISK" "$PART" >/dev/null 2>&1 || true
            resize2fs "$ROOTDEV" >/dev/null 2>&1 || true
          fi
          say "根分区 $(df -h / | awk 'NR==2 {print $2}')"
        }

        say "扩容根分区"
        grow

        # The image's own unattended-upgrades runs at first boot and holds the
        # apt lock while it fetches indexes from the same slow mirror this script
        # is about to use. Stopping it is the difference between "updating
        # sources" taking two minutes and taking an hour.
        systemctl stop unattended-upgrades >/dev/null 2>&1 || true

        # deb.debian.org answers slowly enough from some networks that an index
        # fetch looks like a hang. The mirror is a file in this image, not a URL
        # inside sources.list, so it is rewritten there — and put back if it does
        # not answer, because a fast mirror that is unreachable is worse than a
        # slow one.
        MIRRORDIR=/etc/apt/mirrors
        if [ -d "$MIRRORDIR" ] && [ ! -f "$MIRRORDIR/pocketvm-original" ]; then
          cp "$MIRRORDIR/debian.list" "$MIRRORDIR/debian.list.pocketvm" 2>/dev/null || true
          cp "$MIRRORDIR/debian-security.list" "$MIRRORDIR/debian-security.list.pocketvm" 2>/dev/null || true
          printf '%s\\n' "https://mirrors.163.com/debian" >"$MIRRORDIR/debian.list"
          printf '%s\\n' "https://mirrors.163.com/debian-security" >"$MIRRORDIR/debian-security.list"
          touch "$MIRRORDIR/pocketvm-original"
        fi

        APT_LOCK="-o DPkg::Lock::Timeout=600"
        export DEBIAN_FRONTEND=noninteractive
        say "更新软件源"
        if ! apt-get $APT_LOCK update -qq >>"$LOG" 2>&1; then
          say "163 源不通，改回默认源重试"
          if [ -f "$MIRRORDIR/debian.list.pocketvm" ]; then
            cp "$MIRRORDIR/debian.list.pocketvm" "$MIRRORDIR/debian.list"
            cp "$MIRRORDIR/debian-security.list.pocketvm" "$MIRRORDIR/debian-security.list"
          fi
          apt-get $APT_LOCK update -qq >>"$LOG" 2>&1 || say "软件源更新失败，稍后可在终端重试"
        fi

        say "安装基础软件"
        apt-get $APT_LOCK install -y -qq --no-install-recommends \\
          curl ca-certificates git jq nodejs npm >>"$LOG" 2>&1 \\
          || say "基础软件安装失败，稍后可在终端重试"

        if ! command -v node >/dev/null 2>&1; then
          say "改用 NodeSource 安装 Node"
          curl -fsSL https://deb.nodesource.com/setup_22.x 2>>"$LOG" | bash - >>"$LOG" 2>&1 || true
          apt-get $APT_LOCK install -y -qq nodejs >>"$LOG" 2>&1 || true
        fi
        say "Node $(node --version 2>/dev/null || echo 未安装)"

        if ! command -v codex >/dev/null 2>&1; then
          say "安装 Codex CLI"
          npm install -g --no-fund --no-audit @openai/codex >>"$LOG" 2>&1 || say "Codex 安装失败，可在终端手动重试"
        fi

        if command -v codex >/dev/null 2>&1; then
          say "Codex $(codex --version 2>/dev/null | head -n 1)"
          grow
          # From here on the guest reports its own boot to the host over HTTP,
          # so the host never has to read a ready state out of this console —
          # the console echoes what is typed into it, which is exactly the trap
          # this replaces.
          if curl -fsS -m 30 "http://10.0.2.2:\(Self.helperPort)/pocketvm-report.sh" \
              -o /tmp/pocketvm-report.sh 2>/dev/null; then
            bash /tmp/pocketvm-report.sh --install >/dev/null 2>&1 \\
              || say "上报服务安装失败，下次启动主机仍会用串口确认一次"
          fi
          echo POCKETVM_READY >"$TTY"
        else
          say "安装未完成"
          echo POCKETVM_FAILED >"$TTY"
        fi
        """
    }

    private func indent(_ text: String, spaces: Int) -> String {
        let padding = String(repeating: " ", count: spaces)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : padding + $0 }
            .joined(separator: "\n")
    }
}
