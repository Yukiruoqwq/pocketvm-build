import Foundation

@main struct Tests {
    @MainActor static func main() {
        let auth = CodexAuth()
        let account: [String: Any] = ["account": ["type": "chatgpt"]]
        auth.account(account)
        assert(auth.signInRevision == 1)
        auth.account(account)
        assert(auth.signInRevision == 1)
        for id in ["first", "second"] {
            let previous = auth.signInRevision
            auth.starting()
            auth.login(["type": "chatgptDeviceCode", "loginId": id, "verificationUrl": "https://auth.openai.com/codex/device", "userCode": "ABC"])
            auth.account(account)
            assert(auth.state.isWaiting && auth.signInRevision == previous)
            auth.completed(["loginId": "stale", "success": true])
            assert(auth.signInRevision == previous)
            auth.completed(["loginId": id, "success": true])
            assert(auth.signInRevision == previous + 1 && auth.state == .signedIn)
            auth.completed(["loginId": id, "success": true])
            auth.account(account)
            assert(auth.signInRevision == previous + 1)
        }
        let previous = auth.signInRevision
        auth.starting()
        auth.login(["type": "chatgptDeviceCode", "loginId": "failure", "verificationUrl": "https://auth.openai.com/codex/device", "userCode": "ABC"])
        auth.completed(["loginId": "failure", "success": false])
        assert(auth.signInRevision == previous)
        print("Auth: repeat login, duplicate events, stale events, failure passed")
    }
}
