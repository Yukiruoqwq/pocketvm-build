import Foundation
import Combine

@MainActor
final class CodexAuth: ObservableObject {
    enum State: Equatable {
        case unknown, signedOut, starting, awaitingUser(url: String, code: String), signedIn, failed(String)
        var isWaiting: Bool { if case .starting = self { return true }; if case .awaitingUser = self { return true }; return false }
    }
    @Published private(set) var state: State = .unknown
    let log: [String] = []
    let trace: [String] = []
    private var loginID: String?
    private(set) var signInRevision = 0
    func reset() { loginID = nil; state = .unknown }
    func fail(_ reason: String) { state = .failed(reason) }
    func starting() { loginID = nil; state = .starting }
    func account(_ result: [String: Any]) {
        if state.isWaiting { return }
        if let account = result["account"] as? [String: Any], account["type"] != nil {
            if state != .signedIn { signInRevision += 1 }
            state = .signedIn
        }
        else if !state.isWaiting { state = .signedOut }
    }
    func login(_ result: [String: Any]) {
        guard result["type"] as? String == "chatgptDeviceCode",
              let id = result["loginId"] as? String, let url = result["verificationUrl"] as? String,
              let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
              let code = result["userCode"] as? String else { fail("服务未返回设备登录协议数据"); return }
        loginID = id; state = .awaitingUser(url: url, code: code)
    }
    func completed(_ params: [String: Any]) {
        guard let id = params["loginId"] as? String, id == loginID else { return }
        loginID = nil
        if params["success"] as? Bool == true { signInRevision += 1; state = .signedIn }
        else { fail(params["error"] as? String ?? "登录未完成") }
    }
}
