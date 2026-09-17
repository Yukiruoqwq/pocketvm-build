import SwiftUI
import WebKit

/// Hosts the bundled frontend and relays its calls to the VM.
///
/// The frontend owns presentation; this type owns authority. Any request that
/// changes machine state is validated here before it reaches QEMU, because a
/// web view is not a trust boundary.
struct WebUIView: UIViewRepresentable {
    @ObservedObject var model: VMModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "pocketvm")

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.051, green: 0.051, blue: 0.051, alpha: 1)
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = view
        // Console output is pushed rather than polled: the terminal has to see
        // bytes as they arrive, not on the next frontend request.
        model.pushToWeb = { [weak coordinator = context.coordinator] message in
            coordinator?.reply(message)
        }
        context.coordinator.load(into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "pocketvm")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var model: VMModel
        weak var webView: WKWebView?

        init(model: VMModel) { self.model = model }

        func load(into view: WKWebView) {
            guard let dir = Bundle.main.url(forResource: "web", withExtension: nil) else {
                view.loadHTMLString("<body style='font:14px -apple-system;color:#888;padding:24px'>前端资源缺失</body>", baseURL: nil)
                return
            }
            let index = dir.appendingPathComponent("index.html")
            view.loadFileURL(index, allowingReadAccessTo: dir)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            let payload = body["payload"] as? [String: Any]

            switch action {
            case "getConfig":
                if let config = model.configuration,
                   let data = try? JSONEncoder().encode(config),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    reply(["action": "config", "payload": object])
                }

            case "getProvisionState":
                model.pushProvisionState()
                model.pushAuthState()

            case "start":
                model.start()

            case "stop":
                model.stop()

            case "restart":
                model.restart()

            case "resetProvision":
                // Only the marker, not the downloaded image: an image that has
                // already been verified is the expensive part of a retry.
                model.provisioner.reset()
                model.appendStatus("已清除准备状态，下次启动会重新配置客户机。")
                model.pushProvisionState()

            case "codexLogin":
                model.beginCodexLogin()

            case "codexLoginStatus":
                model.refreshCodexStatus()

            case "openURL":
                // The frontend supplies the URL it was shown, and the view
                // decides what the system is allowed to open.
                if let text = payload?["url"] as? String, let url = URL(string: text) {
                    model.openURL?(url)
                }

            case "saveConfig":
                guard let payload else { return }
                do {
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    // Decoding into the real type rejects anything malformed or
                    // out of range before it can reach the emulator.
                    let incoming = try JSONDecoder().decode(VMConfiguration.self, from: data)
                    try model.applyConfiguration(incoming)
                    reply(["action": "config", "payload": payload])
                } catch {
                    model.appendStatus("配置被拒绝：\(error)")
                }

            case "getMessages":
                reply(["action": "messages", "payload": model.transcriptForUI()])

            case "prompt":
                if let text = payload?["text"] as? String {
                    model.handlePrompt(text)
                }

            case "terminalInput":
                // The frontend sends base64 bytes; hand the guest exactly those.
                if let b64 = payload?["data"] as? String,
                   let data = Data(base64Encoded: b64) {
                    model.writeToConsole(data)
                }

            case "terminalReady", "terminalOpened":
                reply(["action": "terminalState",
                       "payload": ["text": model.isRunning ? "已连接" : "虚拟机未运行"]])

            case "terminalClosed":
                break

            default:
                break
            }
        }

        func reply(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let json = String(data: data, encoding: .utf8) else { return }
            // JSON is data, not source; the parse keeps a stray quote in a
            // guest-supplied string from becoming executable script.
            webView?.evaluateJavaScript(
                "window.pocketvmReceive && window.pocketvmReceive(JSON.parse(\(jsStringLiteral(json))));"
            )
        }

        private func jsStringLiteral(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [value])
            guard let data, var text = String(data: data, encoding: .utf8) else { return "\"\"" }
            text.removeFirst()
            text.removeLast()
            return text
        }
    }
}
