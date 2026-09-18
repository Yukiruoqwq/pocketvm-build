import Foundation

/// Signs the guest's Codex CLI in without leaving the app.
///
/// The guest has no browser, so the CLI's device-code flow is the only one that
/// fits: the CLI prints a URL and a one-time code and then waits for the
/// account to confirm. The app sends the command over the serial console, lifts
/// the two pieces out of the guest's output, and shows them where the user is
/// already looking — the frontend — instead of asking them to read a terminal.
///
/// Everything the guest is asked to run goes through `pocketvm-auth`, a script
/// cloud-init leaves in the guest. Parsing a shell script's output is much less
/// fragile than parsing whatever a TUI decided to draw on a serial line.
@MainActor
final class CodexAuth: ObservableObject {
    enum State: Equatable {
        case unknown
        case signedOut
        case starting
        case awaitingUser(url: String, code: String)
        case signedIn
        case failed(String)

        var isWaiting: Bool {
            switch self {
            case .starting, .awaitingUser: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var log: [String] = []
    /// The last lines the guest actually returned. This is what the settings
    /// page shows when a login is stuck: it separates "the CLI said nothing"
    /// from "the CLI said something the app did not understand".
    @Published private(set) var trace: [String] = []

    private var send: ((String) -> Void)?
    private var timer: Timer?
    private var polls = 0
    private var pendingURL: String?
    private var pendingCode: String?

    /// Starts a device-code login. The command runs in the background inside the
    /// guest so the shell stays usable for polling.
    func begin(send: @escaping (String) -> Void) {
        self.send = send
        cancel()
        pendingURL = nil
        pendingCode = nil
        polls = 0
        log.removeAll()
        trace.removeAll()
        state = .starting
        send("start")
        schedulePoll()
    }

    /// Reads the current state without starting a login. Used when the app
    /// opens so the frontend can show whether the guest is already signed in.
    func refresh(send: @escaping (String) -> Void) {
        self.send = send
        send("status")
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        cancel()
        state = .unknown
        pendingURL = nil
        pendingCode = nil
    }

    func fail(_ reason: String) {
        cancel()
        state = .failed(reason)
    }

    /// One line of guest console output.
    func ingest(line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        noteTrace(text)

        // A shell that cannot find the script means the guest is not ready, or
        // was installed by a build that put it somewhere this shell's PATH does
        // not reach. Polling every eight seconds then only fills the console
        // with the same line, so the poll stops and says so.
        if text.contains("command not found") {
            cancel()
            state = .failed("客户机里没有找到登录脚本：等安装完成后再试一次")
            return
        }

        if text.contains("POCKETVM_AUTH_STATE logged_in") {
            state = .signedIn
            cancel()
            return
        }
        if text.contains("POCKETVM_AUTH_STATE not_logged_in") || text.contains("POCKETVM_AUTH_STATE unknown") {
            if !state.isWaiting { state = .signedOut }
        }
        // The direct CLI prints ordinary prose rather than a marker. Read both
        // forms because the app now sends the command itself instead of relying
        // on the helper that an older guest may not have.
        let lower = text.lowercased()
        if lower.contains("not logged in") {
            if !state.isWaiting { state = .signedOut }
        } else if lower.contains("logged in") {
            state = .signedIn
            cancel()
            return
        }

        guard state.isWaiting else { return }
        if let url = CodexAuth.firstURL(in: text), pendingURL == nil {
            pendingURL = url
        }
        if let code = CodexAuth.firstDeviceCode(in: text), pendingCode == nil {
            pendingCode = code
        }
        if let url = pendingURL, let code = pendingCode, state != .awaitingUser(url: url, code: code) {
            state = .awaitingUser(url: url, code: code)
            log.append("等待在浏览器中确认：\(code)")
        }
    }

    /// The command the host sent, so the trace has both sides of the exchange.
    func noteSent(_ text: String) {
        noteTrace("> \(text)")
    }

    private func noteTrace(_ text: String) {
        trace.append(text)
        if trace.count > 80 {
            trace.removeFirst(trace.count - 80)
        }
    }

    private func schedulePoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A device code is good for fifteen minutes; polling past that
                // only fills the console with commands nobody is waiting for.
                self.polls += 1
                if self.polls > 120 {
                    self.fail("设备登录码已过期，请重新登录")
                    return
                }
                if self.polls > 10, case .starting = self.state {
                    self.cancel()
                    self.state = .failed("登录超时，没有收到 Codex 的输出")
                    return
                }
                self.send?("status")
            }
        }
    }

    // MARK: - Parsing

    /// The CLI prints the verification URL on its own line; taking the first
    /// https token keeps the trailing punctuation of a TUI redraw out of it.
    static func firstURL(in text: String) -> String? {
        guard let range = text.range(of: "https://") else { return nil }
        let tail = text[range.lowerBound...]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        let trimmed = tail.prefix { character in
            character.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        let url = String(trimmed).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        return url.count > "https://".count ? url : nil
    }

    /// Device codes are printed as `XXXX-XXXX`; anything shaped differently is
    /// not worth guessing at.
    static func firstDeviceCode(in text: String) -> String? {
        let pattern = "[A-Z0-9]{4}-[A-Z0-9]{3,8}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }
}
