import Combine
import SwiftUI

@main
struct PocketVMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// What the model picker last chose.
///
/// The frontend owns the preference and writes it through the bridge; the
/// command line is built from it here, because that is where a preference stops
/// being a preference and becomes something the guest is asked to run.
struct ModelSelection {
    var model: String?
    var effort: String?
    var fast: Bool
}

@MainActor
final class VMModel: ObservableObject {
    @Published var consoleText: String = ""
    @Published var status: String = "idle"
    @Published var isRunning = false
    /// Set once the guest has answered the readiness probe. QEMU accepting its
    /// arguments says nothing about the machine being usable, so the frontend
    /// stays behind the gate until this is true.
    @Published private(set) var codexReady = false
    /// The line the gate shows while the machine is coming up.
    @Published private(set) var bootDetail = ""
    @Published var diagnostics: [String] = []
    @Published var configurationSummary: String = ""
    /// Authoritative VM description. The frontend only ever sees a copy.
    @Published var configuration: VMConfiguration?
    /// Messages shown in the frontend's conversation pane.
    @Published var transcript: [[String: Any]] = []
    /// 定时任务 — the scheduled tasks the frontend lists. Persisted so the list
    /// survives a relaunch. Firing them on time still needs the scheduler.
    @Published var automations: [[String: Any]] = []
    /// The models the guest's Codex account can use, as answered by the guest's
    /// own app server. Empty until it has been asked: the list belongs to the
    /// account, so there is nothing truthful to show before that.
    @Published private(set) var models: [[String: Any]] = []
    private var modelsError: String?
    /// The account's usage limits, exactly as the guest's own app server
    /// reported them. Nil until it has, and cached afterwards so the numbers
    /// survive a relaunch.
    @Published private(set) var usageLimits: [String: Any]?
    /// The conversation list, cached the same way: it is what lets the frontend
    /// show the last list it had while the guest is still booting.
    @Published private(set) var threads: [[String: Any]] = []

    let provisioner = Provisioner()
    let auth = CodexAuth()

    private let host = QEMUHost()
    private let hostLog = HostLog()
    private let consoleLimit = 200_000
    /// Serial output arrives in chunks that can split a line, or a UTF-8
    /// character. Lines are only interpreted once they are complete.
    private var consoleBuffer = Data()
    private var observers: [AnyCancellable] = []
    private var probeTask: Task<Void, Never>?
    /// True from the moment stopping is asked for until the emulator has
    /// actually exited. A start during that window is what used to crash the
    /// app: QEMU cannot be initialised twice in one process.
    private var stopping = false
    /// Set once the guest's own OS has been heard from, which is what makes
    /// typing at the console safe.
    private var probeArmed = false

    /// Installed by the web view so console bytes can reach the terminal.
    var pushToWeb: (([String: Any]) -> Void)?
    /// Installed by the view so the frontend can hand a URL to the system.
    var openURL: ((URL) -> Void)?

    init() {
        host.onConsoleBytes = { [weak self] data in
            let encoded = data.base64EncodedString()
            Task { @MainActor in
                guard let self else { return }
                // Base64 rather than a string: the terminal writes bytes, and
                // escape sequences are allowed to straddle a read boundary.
                self.pushToWeb?(["action": "terminalOutput", "payload": ["base64": encoded]])
                self.ingestConsole(data)
            }
        }
        host.onLog = { [weak self] line in
            Task { @MainActor in self?.append(diagnostic: line) }
        }
        host.onExit = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.stopping = false
                self.status = "exited (\(status))"
                self.codexReady = false
                self.bootDetail = ""
                self.probeTask?.cancel()
                self.probeTask = nil
                self.pushProvisionState()
            }
        }
        provisioner.onLog = { [weak self] line in
            Task { @MainActor in self?.append(diagnostic: line) }
        }
        provisioner.onGuestReport = { [weak self] path, body in
            Task { @MainActor in self?.handleGuestReport(path: path, body: body) }
        }
        provisioner.onFinished = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.appendStatus("系统准备完成，登录口令 \(state.password)")
                // The guest only reports this after `codex --version` worked
                // inside it, so the machine is usable at the same moment.
                self.markCodexReady()
                self.refreshCodexStatus()
            }
        }

        // Both state machines are pushed to the frontend rather than polled:
        // the download and the guest's own progress only move when something
        // actually happens.
        provisioner.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.pushProvisionState() }
            }
            .store(in: &observers)
        auth.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.pushAuthState() }
            }
            .store(in: &observers)

        reloadConfiguration()
        loadAutomations()
        loadCachedAccount()
    }

    func reloadConfiguration() {
        do {
            let config = try VMConfiguration.loadOrCreateDefault()
            let validated = config.validated()
            configuration = validated
            configurationSummary = """
            \(validated.name): \(validated.cpuCount) CPU, \
            \(validated.memoryMiB) MiB RAM, \(validated.jitCacheMiB) MiB JIT cache, \
            \(validated.drives.count) drive(s), boot \(validated.boot.mode.rawValue)
            """
        } catch {
            configurationSummary = "configuration error: \(error)"
        }
    }

    /// Persist a configuration that arrived from the frontend.
    ///
    /// The frontend already clamps its own fields, but that is a convenience,
    /// not a guarantee: this is the boundary that decides what the emulator is
    /// allowed to be asked to do.
    func applyConfiguration(_ incoming: VMConfiguration) throws {
        let validated = incoming.validated()
        try validated.write()
        configuration = validated
        reloadConfiguration()
        appendStatus("配置已保存：\(validated.cpuCount) 核 / \(validated.memoryMiB) MiB")
        if isRunning {
            appendStatus("虚拟机正在运行，重启后生效。")
        }
        pushConfiguration()
    }

    func appendStatus(_ text: String) {
        transcript.append(["role": "status", "text": text])
        pushMessages()
    }

    // ------------------------------------------------------------- 定时任务

    private static let automationsKey = "pocketvm.automations"

    func loadAutomations() {
        guard let data = UserDefaults.standard.data(forKey: Self.automationsKey),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        automations = list
    }

    // ------------------------------------------------- 额度与对话列表（缓存）

    private static let limitsKey = "pocketvm.limits"
    private static let threadsKey = "pocketvm.threads"

    /// The last answers the guest gave. Read at launch so the frontend has
    /// something true to draw before the machine is even up; replaced the
    /// moment the guest reports again.
    private func loadCachedAccount() {
        if let data = UserDefaults.standard.data(forKey: Self.limitsKey),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            usageLimits = object
        }
        if let data = UserDefaults.standard.data(forKey: Self.threadsKey),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            threads = list
        }
    }

    func pushAccount() {
        if let usageLimits {
            pushToWeb?(["action": "limits", "payload": usageLimits])
        }
        pushToWeb?(["action": "threads", "payload": ["threads": threads]])
    }

    private func persist(_ object: Any, key: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistAutomations() {
        guard let data = try? JSONSerialization.data(withJSONObject: automations) else { return }
        UserDefaults.standard.set(data, forKey: Self.automationsKey)
    }

    func pushAutomations() {
        pushToWeb?(["action": "automations", "payload": ["tasks": automations]])
    }

    /// Saves one task. The id is generated here, not trusted from the page.
    func upsertAutomation(_ task: [String: Any]) {
        var entry = task
        let id = (task["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        entry["id"] = id
        entry["status"] = entry["status"] as? String ?? "active"
        if let index = automations.firstIndex(where: { $0["id"] as? String == id }) {
            automations[index] = entry
        } else {
            automations.insert(entry, at: 0)
        }
        persistAutomations()
        pushAutomations()
    }

    func removeAutomation(id: String) {
        automations.removeAll { $0["id"] as? String == id }
        persistAutomations()
        pushAutomations()
    }

    func setAutomationStatus(id: String, status: String) {
        guard let index = automations.firstIndex(where: { $0["id"] as? String == id }) else { return }
        automations[index]["status"] = status
        persistAutomations()
        pushAutomations()
    }

    /// Snapshot handed to the web view. Must stay JSON-serialisable.
    func transcriptForUI() -> [[String: Any]] { transcript }

    /// A prompt from the conversation pane.
    ///
    /// The conversation runs in the guest's Codex CLI. Wiring the pane to it
    /// needs an app-server channel, so until that exists the honest answer is
    /// the one the guest can act on: the text goes to the shell, where the user
    /// can see it arrive in the terminal.
    func handlePrompt(_ text: String) {
        transcript.append(["role": "user", "text": text])
        pushMessages()
        guard isRunning else {
            appendStatus("虚拟机未运行，先在设置里启动。")
            return
        }
        appendStatus("消息已发送到客户机终端；对话面板由客户机内的 Codex 接管后即可直接回复。")
        host.writeToConsole(ConsoleText.execCommand(text, selection: storedModelSelection()) + "\n")
    }

    // ------------------------------------------------------------- 模型

    private func storedModelSelection() -> ModelSelection {
        let stored = UserDefaults.standard.dictionary(forKey: "pocketvm.model")
        let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        let model = (stored?["model"] as? String).flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
        let effort = (stored?["effort"] as? String).flatMap { efforts.contains($0) ? $0 : nil }
        return ModelSelection(model: model, effort: effort, fast: (stored?["speed"] as? String) == "fast")
    }

    /// Asks the guest what its Codex account can use.
    ///
    /// The helper is fetched from this app rather than typed out, so a guest
    /// installed by an earlier build answers the same question as a new one.
    func requestModels() {
        guard isRunning, codexReady else { return }
        guard let base = provisioner.helperBaseURL else {
            append(diagnostic: "no helper server is running")
            return
        }
        // Installing the reporter is also how the list is asked for: it reports
        // the models it finds as soon as it runs.
        append(diagnostic: "asking the guest for its model list")
        host.writeToConsole(bootstrapCommand(base: base) + "\n")
    }

    // MARK: - 客户机的上报

    /// The guest telling the host something over HTTP.
    ///
    /// This is what the serial console used to be for. A path and a JSON body
    /// have no echo to mistake for an answer, no CR LF to trim by accident and
    /// no escape sequences to strip — all three of which the console version got
    /// wrong at least once.
    private func handleGuestReport(path: String, body: Data) {
        let text = String(decoding: body, as: UTF8.self)
        append(diagnostic: "guest reported \(path) \(text.prefix(160))")
        switch path {
        case "/ready":
            markCodexReady()
        case "/report":
            apply(report: body)
        default:
            break
        }
    }

    /// One POST carries everything the guest found in a single app-server
    /// session: the models, the usage limits and the conversation list.
    private func apply(report body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        if let list = object["models"] as? [[String: Any]] {
            models = list
            modelsError = nil
            append(diagnostic: "guest reported \(list.count) model(s)")
            pushModels()
        }
        if let limits = object["limits"] as? [String: Any] {
            if let error = limits["error"] as? String {
                append(diagnostic: "usage limits unavailable: \(error)")
            } else {
                usageLimits = limits
                persist(limits, key: Self.limitsKey)
            }
            pushAccount()
        }
        if let list = object["threads"] as? [[String: Any]] {
            threads = list
            persist(list, key: Self.threadsKey)
            append(diagnostic: "guest reported \(list.count) conversation(s)")
            pushAccount()
        }
    }

    /// The one line the host types when the guest has no reporter yet: fetch it
    /// from the host and install it. After that the guest announces its own boot
    /// and nothing has to be typed at the console again.
    private func bootstrapCommand(base: String) -> String {
        "curl -fsS \(base)/pocketvm-report.sh -o /tmp/pocketvm-report.sh"
            + " && sudo bash /tmp/pocketvm-report.sh --install"
    }

    /// Ends in the same state whichever path delivered the list.
    private func applyModels(from data: Data) {
        if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            models = list
            modelsError = nil
            append(diagnostic: "guest reported \(list.count) model(s)")
            pushModels()
            return
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reason = object["error"] as? String {
            models = []
            modelsError = reason
            pushModels()
        }
    }

    func pushModels() {
        var payload: [String: Any] = ["models": models]
        if let modelsError { payload["error"] = modelsError }
        pushToWeb?(["action": "models", "payload": payload])
    }

    /// The guest's answer, as the one line the helper prints.
    private func noteModels(line: String) {
        guard let marker = line.range(of: "POCKETVM_MODELS") else { return }
        let rest = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("FAILED") {
            models = []
            modelsError = String(rest.dropFirst("FAILED".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            append(diagnostic: "model list unavailable: \(modelsError ?? "")")
            pushModels()
            return
        }
        guard let data = rest.data(using: .utf8) else { return }
        applyModels(from: data)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, !stopping else { return }
        Task { await startPrepared() }
    }

    private func startPrepared() async {
        diagnostics.removeAll()
        do {
            let prepared = try await provisioner.prepare()
            configuration = prepared.configuration
            pushConfiguration()
            try host.start(configuration: prepared.configuration, profile: prepared.profile)
            isRunning = true
            codexReady = false
            bootDetail = provisioner.isProvisioned ? "正在启动 QEMU" : ""
            status = "running"
            appendStatus("虚拟机已启动")
            startProbeLoop()
        } catch {
            isRunning = false
            codexReady = false
            bootDetail = ""
            status = "failed"
            append(diagnostic: "\(error)")
            appendStatus("启动失败：\(error)")
        }
        pushProvisionState()
    }

    /// Stops the machine by asking it to stop, and only reports it stopped once
    /// the emulator's own thread has returned.
    ///
    /// The old version dropped everything on the floor immediately: it closed
    /// the console socket, forgot the thread and left QEMU running inside the
    /// app. Starting again then called `qemu_init` a second time, which QEMU
    /// does not survive — that was the crash.
    func stop() {
        guard isRunning, !stopping else { return }
        stopping = true
        status = "stopping"
        bootDetail = "正在关机"
        appendStatus("正在请求客户机关机…")
        probeTask?.cancel()
        probeTask = nil
        host.requestPowerDown()
        pushProvisionState()

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.isRunning, self.stopping else { return }
            self.appendStatus("客户机没有自己关机，改为直接结束模拟器。")
            self.host.requestQuit()
            try? await Task.sleep(for: .seconds(8))
            guard self.isRunning, self.stopping else { return }
            // Better a machine that refuses to stop than one that takes the app
            // down on the next start.
            self.stopping = false
            self.status = "running"
            self.bootDetail = ""
            self.appendStatus("模拟器没有退出。为了不让下一次启动把 App 弄崩，这里不强行清理；彻底退出 App 可以停掉它。")
            self.pushProvisionState()
        }
    }

    /// Restarts by stopping first and waiting for the emulator to actually be
    /// gone, because a second `qemu_init` while the first one is still in there
    /// is the crash this whole path exists to avoid.
    func restart() {
        guard !stopping else { return }
        stop()
        Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if !self.isRunning { break }
            }
            guard let self, !self.isRunning else { return }
            await self.startPrepared()
        }
    }

    // MARK: - Codex sign-in

    func beginCodexLogin() {
        guard isRunning else {
            appendStatus("先启动虚拟机，再登录 Codex。")
            return
        }
        appendStatus("正在向客户机请求设备代码…")
        auth.begin { [weak self] command in
            self?.host.writeToConsole(command + "\n")
        }
    }

    func refreshCodexStatus() {
        guard isRunning else { return }
        auth.refresh { [weak self] command in
            self?.host.writeToConsole(command + "\n")
        }
    }

    // MARK: - Console

    /// Raw bytes from the terminal. Control characters, partial escape
    /// sequences and any non-UTF-8 byte all have to survive intact.
    func writeToConsole(_ data: Data) {
        guard isRunning else { return }
        host.writeToConsole(data)
    }

    private func ingestConsole(_ data: Data) {
        consoleBuffer.append(data)
        while let newline = consoleBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(consoleBuffer[consoleBuffer.startIndex..<newline])
            consoleBuffer = Data(consoleBuffer[consoleBuffer.index(after: newline)...])
            let line = ConsoleText.plain(String(decoding: lineData, as: UTF8.self))
            provisioner.ingest(consoleLine: line)
            auth.ingest(line: line)
            noteModels(line: line)
            noteBoot(line: line)
        }
        // A guest that never emits a newline must not grow this without bound.
        if consoleBuffer.count > 256 * 1024 { consoleBuffer.removeAll() }
    }

    // MARK: - Boot

    /// The one line the host types into the guest to find out whether the
    /// machine can be used yet.
    ///
    /// There is no channel inside the guest to announce that its shell is up,
    /// so the host asks: while the guest is still booting the text lands
    /// nowhere, and once something is reading the console it answers. The guest
    /// also carries a service that prints the same marker on later boots, so
    /// this is the fallback rather than the only path.
    private static let probeCommand =
        "if command -v codex >/dev/null 2>&1; then echo POCKETVM_CODEX_READY; else echo POCKETVM_NO_CODEX; fi"

    /// Follows the guest's own console so the gate can say where the machine is.
    private func noteBoot(line: String) {
        guard isRunning else { return }
        // An exact line, not a substring: the probe the host types contains this
        // same string, and the guest's console echoes what is typed. Matching a
        // substring lifted the glass on the echo — milliseconds after the probe
        // was sent, before the guest had answered anything.
        // Trimmed of newlines as well as spaces: the guest's tty ends every line
        // with CR LF, and `.whitespaces` leaves that CR behind, so an
        // exactly-printed marker never compared equal — the machine sat at
        // 正在启动 Codex CLI while its disk was being written the whole time.
        if line.trimmingCharacters(in: .whitespacesAndNewlines) == "POCKETVM_CODEX_READY" {
            markCodexReady()
            return
        }
        guard provisioner.isProvisioned, !codexReady else { return }

        // The gate starts at 正在启动 QEMU; anything at all from the guest means
        // the emulator is up and the guest is the thing booting now.
        if bootDetail == "正在启动 QEMU" {
            bootDetail = "正在引导系统"
            pushProvisionState()
        }

        // A shell prompt is the one line that proves something is reading the
        // console, so the probe is answered as soon as it is typed.
        if line.contains("@pocketvm:") {
            append(diagnostic: "shell prompt seen")
            sendProbe()
            return
        }
        // Anything else only shortens the wait before the loop starts typing.
        if bootDetail != "正在启动 Codex CLI", lineLooksLikeGuestBoot(line) {
            if !probeArmed { append(diagnostic: "guest boot output seen") }
            probeArmed = true
        }
    }

    /// Lines the firmware and the boot loader do not print.
    ///
    /// The distribution's own name is deliberately not one of them: GRUB's menu
    /// entry says "Debian GNU/Linux" long before the guest is running, which is
    /// exactly how the probe used to end up typed at the boot menu and the gate
    /// skipped straight from 正在启动 QEMU to 正在启动 Codex CLI.
    private func lineLooksLikeGuestBoot(_ line: String) -> Bool {
        line.contains("Linux version")
            || line.contains("systemd[")
            || line.contains("Reached target")
            || line.contains("cloud-init")
    }

    private func sendProbe() {
        if bootDetail != "正在启动 Codex CLI" {
            bootDetail = "正在启动 Codex CLI"
            pushProvisionState()
        }
        // A guest installed by this build reports its own boot over HTTP, so
        // this is only the migration path: teach an older guest to do the same,
        // and it will answer over the channel rather than through the terminal.
        guard let base = provisioner.helperBaseURL else {
            // No channel to teach: the old line at least still gets an answer
            // from a guest that was already migrated by hand.
            host.writeToConsole(Self.probeCommand + "\n")
            return
        }
        append(diagnostic: "teaching the guest to report its own boot")
        host.writeToConsole(bootstrapCommand(base: base) + "\n")
    }

    private func markCodexReady() {
        guard !codexReady else { return }
        codexReady = true
        bootDetail = ""
        probeArmed = false
        probeTask?.cancel()
        probeTask = nil
        append(diagnostic: "guest answered the readiness probe")
        pushProvisionState()
        // The machine is usable, so the account's model list can be asked for.
        // It may legitimately fail until the user signs in; that answer is
        // reported to the frontend rather than papered over with a guess.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.models.isEmpty else { return }
            self.requestModels()
        }
    }

    /// A slow machine can take minutes to reach a prompt, and the boot menu
    /// reads the serial line, so nothing is typed at it until the guest itself
    /// has been heard from. Once it has, the retries are frequent; before that
    /// they are slow enough to stay out of the boot's way.
    private func startProbeLoop() {
        probeTask?.cancel()
        probeArmed = false
        probeTask = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled {
                let armed = self?.probeArmed ?? false
                // The first blind attempt is early on purpose: the gate should
                // not depend on the guest printing anything the host recognises,
                // and the command is harmless if the shell is not there yet.
                let wait: Duration = armed ? .seconds(10) : (attempts < 1 ? .seconds(45) : .seconds(60))
                try? await Task.sleep(for: wait)
                guard let self, self.isRunning, !self.codexReady else { return }
                attempts += 1
                self.sendProbe()
            }
        }
    }

    private func append(console text: String) {
        consoleText += text
        if consoleText.count > consoleLimit {
            consoleText = String(consoleText.suffix(consoleLimit))
        }
    }

    private func append(diagnostic line: String) {
        hostLog.write(line)
        diagnostics.append(line)
        if diagnostics.count > 400 {
            diagnostics.removeFirst(diagnostics.count - 400)
        }
    }

    // MARK: - Frontend

    func pushProvisionState() {
        let stage = provisioner.stage
        // Read from disk rather than remembered, so the frontend's 输出内容 list
        // cannot drift from what the machine has actually written. Empty until
        // there is a guest, because before that there is nothing to show.
        let outputs: [[String: String]] = provisioner.isProvisioned ? documentsListing() : []
        var payload: [String: Any] = [
            "stage": stage.description,
            "busy": stage.isActive,
            "provisioned": provisioner.isProvisioned,
            "image": provisioner.image.displayName,
            "imageBytes": Int(provisioner.image.capacityGiB),
            "host": provisioner.image.remoteURL.host ?? "",
            "source": "\(provisioner.image.remoteURL.host ?? "") · \(provisioner.image.remoteURL.lastPathComponent)",
            "outputs": outputs,
            "password": provisioner.state.password,
            "running": isRunning,
            "stopping": stopping,
            "codexReady": codexReady,
            "detail": bootDetail,
            "cpuCount": configuration?.cpuCount ?? 0,
            "memoryMiB": configuration?.memoryMiB ?? 0,
            "status": status,
        ]
        switch stage {
        case .downloading(let fraction): payload["fraction"] = fraction
        case .verifying(let fraction): payload["fraction"] = fraction
        default: break
        }
        pushToWeb?(["action": "provisionState", "payload": payload])
    }

    /// The files in the app's documents directory, one level deep: the disk
    /// image lives in `Images/`, and everything else sits beside it.
    private func documentsListing() -> [[String: String]] {
        let root = VMConfiguration.documentsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var entries: [[String: String]] = []
        for name in names.sorted() {
            let url = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                for child in children.sorted() {
                    let childURL = url.appendingPathComponent(child)
                    let size = (try? childURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    entries.append(["name": "\(name)/\(child)", "size": Self.formattedBytes(size)])
                }
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                entries.append(["name": name, "size": Self.formattedBytes(size)])
            }
        }
        return Array(entries.prefix(12))
    }

    private static func formattedBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    func pushAuthState() {
        var payload: [String: Any] = ["log": auth.log]
        switch auth.state {
        case .unknown: payload["state"] = "unknown"
        case .signedOut: payload["state"] = "signedOut"
        case .starting: payload["state"] = "starting"
        case .awaitingUser(let url, let code):
            payload["state"] = "awaiting"
            payload["url"] = url
            payload["code"] = code
        case .signedIn: payload["state"] = "signedIn"
        case .failed(let reason):
            payload["state"] = "failed"
            payload["reason"] = reason
        }
        pushToWeb?(["action": "authState", "payload": payload])
    }

    func pushMessages() {
        pushToWeb?(["action": "messages", "payload": transcriptForUI()])
    }

    func pushConfiguration() {
        guard let configuration,
              let data = try? JSONEncoder().encode(configuration),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        pushToWeb?(["action": "config", "payload": object])
    }
}

/// Serial output is written by a terminal, not by an API: it carries escape
/// sequences, and the parts that are read as data have to be separated from the
/// parts that are only there to be drawn.
enum ConsoleText {
    private static let patterns = [
        "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
        "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
        "\u{1B}[@-Z\\\\-_]",
    ]

    static func plain(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    /// One word for the guest's shell, quoted so nothing in it is read as
    /// syntax. A prompt is arbitrary text from the user, and so is a model id.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `codex exec` line for one prompt.
    ///
    /// `-c` overrides the guest's own configuration for this run only, which is
    /// exactly what the picker in the frontend promises: a model, a reasoning
    /// level, and optionally the faster service tier, for the next prompt.
    static func execCommand(_ text: String, selection: ModelSelection) -> String {
        var parts = ["codex", "exec"]
        if let model = selection.model { parts.append("--model \(shellQuoted(model))") }
        if let effort = selection.effort { parts.append("-c model_reasoning_effort=\(shellQuoted(effort))") }
        if selection.fast { parts.append("-c service_tier=fast") }
        parts.append(shellQuoted(text))
        return parts.joined(separator: " ")
    }
}

struct ContentView: View {
    @StateObject private var model = VMModel()
    @State private var showDiagnostics = false
    @State private var showConsole = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WebUIView(model: model)
                .ignoresSafeArea()

            // The console is the escape hatch when the frontend itself is the
            // thing that is broken, so it stays out of the way of the surface.
            Button {
                showConsole = true
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(11)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(18)
            .accessibilityLabel("串口控制台")
        }
        .onAppear {
            model.openURL = { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return }
                UIApplication.shared.open(url)
            }
        }
        .sheet(isPresented: $showConsole) {
            ConsoleSheet(model: model, showDiagnostics: $showDiagnostics)
        }
        .sheet(isPresented: $showDiagnostics) {
            diagnosticsSheet
        }
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.diagnostics.isEmpty {
                        Text("No host messages yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Host log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDiagnostics = false }
                }
            }
        }
    }
}
