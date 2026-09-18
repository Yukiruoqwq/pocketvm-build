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

@MainActor
final class VMModel: ObservableObject {
    @Published var consoleText: String = ""
    @Published var status: String = "idle"
    @Published var isRunning = false
    @Published var diagnostics: [String] = []
    @Published var configurationSummary: String = ""
    /// Authoritative VM description. The frontend only ever sees a copy.
    @Published var configuration: VMConfiguration?
    /// Messages shown in the frontend's conversation pane.
    @Published var transcript: [[String: Any]] = []

    let provisioner = Provisioner()
    let auth = CodexAuth()

    private let host = QEMUHost()
    private let hostLog = HostLog()
    private let consoleLimit = 200_000
    /// Serial output arrives in chunks that can split a line, or a UTF-8
    /// character. Lines are only interpreted once they are complete.
    private var consoleBuffer = Data()
    private var observers: [AnyCancellable] = []

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
                self?.isRunning = false
                self?.status = "exited (\(status))"
            }
        }
        provisioner.onLog = { [weak self] line in
            Task { @MainActor in self?.append(diagnostic: line) }
        }
        provisioner.onFinished = { [weak self] state in
            Task { @MainActor in
                self?.appendStatus("系统准备完成，登录口令 \(state.password)")
                self?.refreshCodexStatus()
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
        host.writeToConsole(ConsoleText.quotedCommand(text) + "\n")
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
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
            status = "running"
            appendStatus("虚拟机已启动")
        } catch {
            isRunning = false
            status = "failed"
            append(diagnostic: "\(error)")
            appendStatus("启动失败：\(error)")
        }
        pushProvisionState()
    }

    func stop() {
        host.stop()
        isRunning = false
        status = "stopped"
    }

    func restart() {
        host.stop()
        isRunning = false
        Task { await startPrepared() }
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
        }
        // A guest that never emits a newline must not grow this without bound.
        if consoleBuffer.count > 256 * 1024 { consoleBuffer.removeAll() }
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
        var payload: [String: Any] = [
            "stage": stage.description,
            "busy": stage.isActive,
            "provisioned": provisioner.isProvisioned,
            "image": provisioner.image.displayName,
            "imageBytes": Int(provisioner.image.capacityGiB),
            "password": provisioner.state.password,
            "running": isRunning,
            "status": status,
        ]
        switch stage {
        case .downloading(let fraction): payload["fraction"] = fraction
        case .verifying(let fraction): payload["fraction"] = fraction
        default: break
        }
        pushToWeb?(["action": "provisionState", "payload": payload])
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

    /// Wraps text for the guest shell so a prompt cannot be read as syntax.
    static func quotedCommand(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "codex exec '\(escaped)'"
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
