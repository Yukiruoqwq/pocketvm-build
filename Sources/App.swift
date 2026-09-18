import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    private var bootProgress = BootProgress()
    private var bootStartedAt: TimeInterval = 0
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
    /// One refresh per sign-in, not one per state push.
    private var refreshedAfterSignIn = false
    /// The account's usage limits, exactly as the guest's own app server
    /// reported them. Nil until it has, and cached afterwards so the numbers
    /// survive a relaunch.
    @Published private(set) var usageLimits: [String: Any]?
    /// What the account is: the address it belongs to and the plan behind it,
    /// again exactly as the guest reported it.
    @Published private(set) var account: [String: Any]?
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
    /// Presses Enter for a boot loader that is waiting for a key.
    /// True from the moment stopping is asked for until the emulator has
    /// actually exited. A start during that window is what used to crash the
    /// app: QEMU cannot be initialised twice in one process.
    private var stopping = false
    private var starting = false
    @Published private(set) var executionMode: ExecutionMode?
    private var promptInFlight = false
    private var selectedThreadID: String?
    /// Set once the guest's own OS has been heard from, which is what makes
    /// typing at the console safe.

    /// Installed by the web view so console bytes can reach the terminal.
    var pushToWeb: (([String: Any]) -> Void)?
    /// Installed by the view so the frontend can hand a URL to the system.
    var openURL: ((URL) -> Void)?
    /// Set by the frontend to ask for the system's file picker; the view owns
    /// presenting it, because a web view cannot.
    @Published var wantsDiskPicker = false

    init() {
        // The SwiftUI console sheet and the xterm terminal share one serial
        // stream. This callback is what fills the sheet's plain-text view; the
        // byte callback below feeds xterm. Without this, the sheet was wired to
        // a published string that nothing ever wrote, so it stayed on its
        // placeholder even while the guest was printing on the same console.
        host.onConsoleOutput = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.append(console: ConsoleText.plain(text))
            }
        }
        host.onConsoleBytes = { [weak self] data in
            let encoded = data.base64EncodedString()
            Task { @MainActor in
                guard let self else { return }
                // Base64 rather than a string: the terminal writes bytes, and
                // escape sequences are allowed to straddle a read boundary.
                self.pushToWeb?(["action": "terminalOutput", "payload": ["base64": encoded]])

            }
        }
        host.onLog = { [weak self] line in
            Task { @MainActor in self?.append(diagnostic: line) }
        }
        host.onGuestRunning = { [weak self] in
            Task { @MainActor in self?.advanceBoot(to: .system) }
        }
        host.onBootStatusError = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isRunning, !self.codexReady else { return }
                self.bootDetail = reason
                self.append(diagnostic: reason)
                self.pushProvisionState()
            }
        }
        host.onExit = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.auth.reset()
                self.provisioner.cancelCommands()
                self.isRunning = false
                self.stopping = false
                self.status = "exited (\(status))"
                self.codexReady = false
                self.bootDetail = ""
                self.pushProvisionState()
            }
        }
        provisioner.channel.onProcessStarted = { [weak self] in
            self?.advanceBoot(to: .codex)
        }
        provisioner.channel.onState = { [weak self] ready, error in
            guard let self else { return }
            if ready { self.markCodexReady() } else {
                self.codexReady = false; self.auth.reset(); self.promptInFlight = false
                self.bootDetail = error ?? "正在连接 Codex 服务"
                self.pushProvisionState()
            }
        }
        provisioner.channel.onEvent = { [weak self] message in self?.handleCodexEvent(message) }
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
                // Installation only proves that the binary was written. The
                // running guest still has to start its report service and CLI;
                // The persistent protocol channel owns CLI readiness.
                self.pushProvisionState()
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
        // Which build is running, in the log: every rebuild keeps the same
        // bundle version unless this says otherwise, and "did the new one get
        // installed" has been a real question more than once.
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        append(diagnostic: "PocketVM \(short) (\(build))")
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

    /// Copies a disk image the user picked into the app's own documents and adds
    /// it to the machine.
    ///
    /// The file comes from outside the sandbox, so it is copied rather than
    /// referenced: the URL a picker hands back stops being usable when the
    /// picker closes, and the emulator needs it on every boot.
    func addDisk(from result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            appendStatus("没有选择磁盘：\(error.localizedDescription)")
        case .success(let urls):
            guard let source = urls.first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let name = source.lastPathComponent
                let destination = VMConfiguration.documentsDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)

                var config = try VMConfiguration.loadOrCreateDefault()
                config.drives.append(
                    VMConfiguration.Drive(
                        path: name,
                        // Read-only virtio rather than USB: the USB path names a
                        // single device id, so a second one would collide.
                        interface: .virtio,
                        readOnly: true,
                        format: name.hasSuffix(".qcow2") ? "qcow2" : "raw"
                    )
                )
                let validated = config.validated()
                try validated.write()
                configuration = validated
                pushConfiguration()
                pushProvisionState()
                appendStatus("已添加 \(name)，重启后生效。")
            } catch {
                appendStatus("添加磁盘失败：\(error)")
            }
        }
    }

    func appendStatus(_ text: String) {
        // Status belongs in the host log, not in the conversation. These lines
        // were the ones filling the thread with machine messages.
        append(diagnostic: "status: \(text)")
    }

    /// A line the frontend wants in the host log. The page has no other way to
    /// leave evidence behind.
    func noteFromWeb(_ text: String) {
        append(diagnostic: "web: \(text)")
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
    private static let accountKey = "pocketvm.account"

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
        if let data = UserDefaults.standard.data(forKey: Self.accountKey),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            account = object
        }
    }

    func pushAccount() {
        if let usageLimits {
            pushToWeb?(["action": "limits", "payload": usageLimits])
        }
        if let account {
            pushToWeb?(["action": "account", "payload": account])
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
        guard let title = task["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 240 else { return }
        entry["title"] = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
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
        guard ["active", "paused", "completed"].contains(status) else { return }
        guard let index = automations.firstIndex(where: { $0["id"] as? String == id }) else { return }
        automations[index]["status"] = status
        persistAutomations()
        pushAutomations()
    }

    /// Snapshot handed to the web view. Must stay JSON-serialisable.
    func transcriptForUI() -> [[String: Any]] { transcript }

    /// A prompt from the conversation pane.
    ///
    /// Execute through the command agent and return structured CLI events.
    /// Serial input belongs exclusively to the interactive terminal.
    private var messageIndices: [String: Int] = [:]
    private func rpc(_ method: String, _ params: [String: Any] = [:], done: @escaping ([String: Any]) -> Void) {
        provisioner.channel.request(method, params) { [weak self] message in
            if let error = message["error"] as? [String: Any] {
                self?.appendStatus(error["message"] as? String ?? "协议请求失败")
                if ["turn/start", "thread/start", "thread/resume"].contains(method) { self?.promptInFlight = false }
                if method == "account/login/start" { self?.auth.fail(error["message"] as? String ?? "登录失败") }
                return
            }
            guard let result = message["result"] as? [String: Any] else { return }
            done(result)
        }
    }
    func handlePrompt(_ text: String) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
        guard !text.isEmpty, isRunning, codexReady, !promptInFlight else { return }
        promptInFlight = true
        transcript.append(["role": "user", "text": text]); pushMessages()
        let send: (String) -> Void = { [weak self] id in
            guard let self else { return }
            let selection = self.storedModelSelection()
            var params: [String: Any] = ["threadId": id, "input": [["type": "text", "text": text, "text_elements": []]]]
            if let model = selection.model { params["model"] = model }
            if let effort = selection.effort { params["effort"] = effort }
            if selection.fast { params["serviceTier"] = "fast" }
            self.rpc("turn/start", params) { _ in }
        }
        if let id = selectedThreadID { rpc("thread/resume", ["threadId": id]) { _ in send(id) } }
        else {
            rpc("thread/start", ["cwd": "/home/codex", "approvalPolicy": "on-request", "sandbox": "workspace-write"]) { [weak self] result in
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { self?.promptInFlight = false; return }
                self?.selectedThreadID = id; send(id)
            }
        }
    }
    func selectThread(_ id: String?) {
        guard !promptInFlight else { appendStatus("请等待当前回复完成"); return }
        selectedThreadID = id; transcript = []; messageIndices = [:]; pushMessages()
        guard let id else { return }
        rpc("thread/resume", ["threadId": id]) { [weak self] result in
            guard let self, self.selectedThreadID == id, let thread = result["thread"] as? [String: Any] else { return }
            for turn in thread["turns"] as? [[String: Any]] ?? [] {
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    if item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                        self.transcript.append(["role": "assistant", "text": text])
                    } else if item["type"] as? String == "userMessage" {
                        let content = item["content"] as? [[String: Any]] ?? []
                        self.transcript.append(["role": "user", "text": content.compactMap { $0["text"] as? String }.joined(separator: "\n")])
                    }
                }
            }
            self.pushMessages()
        }
    }
    private func handleCodexEvent(_ message: [String: Any]) {
        guard let method = message["method"] as? String, let params = message["params"] as? [String: Any] else { return }
        if method == "account/login/completed" { auth.completed(params); refreshCodexStatus(); requestModels(); return }
        if method == "account/updated" { refreshCodexStatus(); return }
        guard params["threadId"] as? String == selectedThreadID else { return }
        if method == "turn/completed" {
            promptInFlight = false
            if let turn = params["turn"] as? [String: Any], let error = turn["error"] as? [String: Any] { appendStatus(error["message"] as? String ?? "回合失败") }
            requestModels()
        }
        if method == "item/agentMessage/delta", let id = params["itemId"] as? String, let delta = params["delta"] as? String {
            let index: Int
            if let existing = messageIndices[id] { index = existing }
            else { index = transcript.count; messageIndices[id] = index; transcript.append(["role": "assistant", "text": ""]) }
            transcript[index]["text"] = (transcript[index]["text"] as? String ?? "") + delta
            pushMessages()
        }
        if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
           let id = item["id"] as? String, let text = item["text"] as? String {
            if let index = messageIndices[id] { transcript[index]["text"] = text }
            else { messageIndices[id] = transcript.count; transcript.append(["role": "assistant", "text": text]) }
            pushMessages()
        }
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
        rpc("model/list", ["includeHidden": true, "limit": 100]) { [weak self] result in
            self?.models = result["data"] as? [[String: Any]] ?? []; self?.pushModels()
        }
        rpc("thread/list", ["limit": 50]) { [weak self] result in
            self?.threads = result["data"] as? [[String: Any]] ?? []; self?.pushAccount()
        }
        rpc("account/rateLimits/read") { [weak self] result in self?.usageLimits = result; self?.pushAccount() }
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
        case "/boot":
            provisioner.acknowledgeSystemBoot()
            // The guest's own system is up and reachable. Everything left is
            // the CLI inside it, which is the step the gate name refers to.
            noteGuestSystemUp()
        case "/boot-error":
            let report = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            bootDetail = report?["error"] as? String ?? "CLI 启动检查失败"
            appendStatus(bootDetail)
            pushProvisionState()
        default:
            break
        }
    }

    private func noteGuestSystemUp() {
        advanceBoot(to: .system)
    }

    private func logBootPhase() {
        let elapsed = ProcessInfo.processInfo.systemUptime - bootStartedAt
        append(diagnostic: String(format: "boot phase %@ at +%.3f seconds", bootProgress.phase.code, elapsed))
    }

    private func advanceBoot(to phase: BootProgress.Phase) {
        guard (starting || isRunning), !stopping, !codexReady else { return }
        let previous = bootProgress.phase
        bootProgress.advance(to: phase)
        if previous != bootProgress.phase { logBootPhase() }
        bootDetail = bootProgress.phase.detail
        pushProvisionState()
    }

    /// One POST carries everything the guest found in a single app-server
    /// session: the models, the usage limits and the conversation list.
    func pushModels() {
        var payload: [String: Any] = ["models": models]
        if let modelsError { payload["error"] = modelsError }
        pushToWeb?(["action": "models", "payload": payload])
    }

    /// The guest's answer, as the one line the helper prints.
    // MARK: - Lifecycle

    func start() {
        guard !isRunning, !stopping, !starting else { return }
        Task { await startPrepared() }
    }

    private func startPrepared() async {
        guard !isRunning, !stopping, !starting else { return }
        starting = true
        codexReady = false
        bootProgress = BootProgress()
        bootStartedAt = ProcessInfo.processInfo.systemUptime
        logBootPhase()
        bootDetail = bootProgress.phase.detail
        executionMode = .select(jitAvailable: JIT.isDebugged)
        pushProvisionState()
        refreshedAfterSignIn = false
        defer { starting = false; pushProvisionState() }
        auth.reset()
        diagnostics.removeAll()
        consoleBuffer.removeAll(keepingCapacity: true)
        do {
            let prepared = try await provisioner.prepare()
            configuration = prepared.configuration
            pushConfiguration()
            try host.start(configuration: prepared.configuration, profile: prepared.profile, mode: executionMode ?? .interpreter)
            isRunning = true
            codexReady = false
            bootDetail = bootProgress.phase.detail
            status = "running"
            appendStatus("虚拟机已启动")
            // Readiness is reported by the guest agent over the helper HTTP
            // channel. Starting blind serial probes here used to type commands
            // into GRUB, cloud-init and login shells at unpredictable times.
        } catch {
            isRunning = false
            codexReady = false
            bootDetail = ""
            status = "failed"
            provisioner.failBoot(error)
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
            self.appendStatus("模拟器没有退出；退出 App 可以停掉它。")
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
        guard codexReady, !auth.state.isWaiting else { return }
        auth.starting()
        rpc("account/login/start", ["type": "chatgptDeviceCode"]) { [weak self] result in self?.auth.login(result) }
    }
    func refreshCodexStatus() {
        guard codexReady else { return }
        rpc("account/read", ["refreshToken": false]) { [weak self] result in
            self?.auth.account(result); self?.account = result; self?.pushAccount()
        }
    }

    // MARK: - Proxy subscription

    /// The Clash subscription the guest should reach OpenAI through, if the
    /// owner has given one.
    ///
    /// It is a credential, so it is kept in the app's Documents on the device:
    /// the build is public, the subscription is not.
    func proxySubscription() -> String {
        let file = VMConfiguration.documentsDirectory.appendingPathComponent("proxy.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("http") } ?? ""
    }

    func setProxySubscription(_ url: String) {
        let file = VMConfiguration.documentsDirectory.appendingPathComponent("proxy.txt")
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: file)
            appendStatus("已清除代理订阅。")
            return
        }
        guard let parsed = URL(string: trimmed),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host != nil else {
            appendStatus("订阅链接要以 http 开头。")
            return
        }
        do {
            try (trimmed + "\n").write(to: file, atomically: true, encoding: .utf8)
            appendStatus("已记下代理订阅，重启虚拟机后客户机会自行安装。")
        } catch {
            appendStatus("保存订阅失败：\(error)")
        }
    }

    // MARK: - Console

    /// Raw bytes from the terminal. Control characters, partial escape
    /// sequences and any non-UTF-8 byte all have to survive intact.
    func writeToConsole(_ data: Data) {
        guard isRunning else { return }
        host.writeToConsole(data)
    }

    private func markCodexReady() {
        // A real guest JSON-RPC handshake also proves that direct boot succeeded.
        provisioner.acknowledgeSystemBoot()
        bootProgress.advance(to: .ready)
        logBootPhase()
        guard !codexReady else { return }
        codexReady = true
        bootDetail = ""
        append(diagnostic: "guest app-server initialized")
        refreshCodexStatus()
        pushProvisionState()
        // The machine is usable, so the account's model list can be asked for.
        // It may legitimately fail until the user signs in; that answer is
        // reported to the frontend rather than papered over with a guess.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isRunning, self.codexReady else { return }
            self.requestModels()
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
            "stageCode": stage.code,
            "busy": stage.isActive || starting,
            "starting": starting,
            "provisioned": provisioner.isProvisioned,
            "image": provisioner.image.displayName,
            "imageBytes": Int(provisioner.image.capacityGiB),
            "host": provisioner.image.remoteURL.host ?? "",
            "source": "\(provisioner.image.remoteURL.host ?? "") · \(provisioner.image.remoteURL.lastPathComponent)",
            "outputs": outputs,
            "password": provisioner.state.password,
            "running": isRunning,
            "executionMode": executionMode?.rawValue ?? "idle",
            "stopping": stopping,
            "codexReady": codexReady,
            "detail": bootDetail,
            "bootPhase": bootProgress.phase.code,
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
        var payload: [String: Any] = ["log": auth.log, "trace": auth.trace]
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
        // Signing in changes what the account has, so the models, the limits and
        // the conversation list are asked for again rather than left stale.
        if case .signedIn = auth.state, !refreshedAfterSignIn {
            refreshedAfterSignIn = true
            requestModels()
        }
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
            .padding(.bottom, model.executionMode == .interpreter ? 24 : 0)
            .accessibilityLabel("串口控制台")
        }
        .onAppear {
            model.openURL = { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return }
                UIApplication.shared.open(url)
            }
        }
        // 添加磁盘: the picker belongs to the view, the file belongs to the model.
        .fileImporter(
            isPresented: $model.wantsDiskPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            model.addDisk(from: result)
        }
        .sheet(isPresented: $showConsole) {
            ConsoleSheet(model: model, showDiagnostics: $showDiagnostics)
                .safeAreaInset(edge: .bottom, alignment: .trailing) {
                    if model.executionMode == .interpreter { SlowModeLabel() }
                }
        }
        .sheet(isPresented: $showDiagnostics) {
            diagnosticsSheet
                .safeAreaInset(edge: .bottom, alignment: .trailing) {
                    if model.executionMode == .interpreter { SlowModeLabel() }
                }
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

private struct SlowModeLabel: View {
    var body: some View {
        Text("慢速模式")
            .font(.system(size: 12))
            .foregroundStyle(Color(red: 0.835, green: 0.627, blue: 0))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
    }
}
