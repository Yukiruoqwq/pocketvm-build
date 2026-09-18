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
        view.navigationDelegate = context.coordinator
        WebUIView.disableZoom(on: view)
        context.coordinator.webView = view
        // Console output is pushed rather than polled: the terminal has to see
        // bytes as they arrive, not on the next frontend request.
        model.pushToWeb = { [weak coordinator = context.coordinator] message in
            coordinator?.reply(message)
        }
        context.coordinator.load(into: view)
        return view
    }

    /// The tablet keeps its own scale. The viewport meta and the frontend's own
    /// gesture handlers cover the page; this covers the scroll view, which
    /// would otherwise still zoom on a pinch or a double tap. It is applied
    /// again when the page finishes loading, because a zooming recogniser
    /// installed after the first pass would not be covered by the first one.
    static func disableZoom(on view: WKWebView) {
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 1
        view.scrollView.bouncesZoom = false
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        for recognizer in view.scrollView.gestureRecognizers ?? [] {
            if let pinch = recognizer as? UIPinchGestureRecognizer {
                pinch.isEnabled = false
            }
            if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
                tap.isEnabled = false
            }
        }
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "pocketvm")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var model: VMModel
        weak var webView: WKWebView?

        /// 外观 — a preference of the page, remembered here so it survives a
        /// relaunch without the machine having to be involved.
        private static let appearanceKey = "pocketvm.appearance"
        private static let appearances = ["light", "dark", "system"]
        private static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        private static let speeds = ["standard", "fast"]

        /// A model id ends up inside a command the guest runs, so it has to look
        /// like an identifier and nothing else.
        static func isSafeToken(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 64
                && value.allSatisfy { $0.isLetter || $0.isNumber || "._-:".contains($0) }
        }

        init(model: VMModel) { self.model = model }

        static var storedAppearance: String {
            let stored = UserDefaults.standard.string(forKey: appearanceKey) ?? "system"
            return appearances.contains(stored) ? stored : "system"
        }

        func load(into view: WKWebView) {
            guard let dir = Bundle.main.url(forResource: "web", withExtension: nil) else {
                view.loadHTMLString("<body style='font:14px -apple-system;color:#888;padding:24px'>前端资源缺失</body>", baseURL: nil)
                return
            }
            let index = dir.appendingPathComponent("index.html")
            view.loadFileURL(index, allowingReadAccessTo: dir)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            WebUIView.disableZoom(on: webView)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            let payload = body["payload"] as? [String: Any]

            // Every call from the page is named in the host log. "The button
            // did nothing" then answers itself: either the page never called,
            // or it called and the host refused. Keystrokes are excluded —
            // each one would be a line.
            if action != "terminalInput" {
                model.noteFromWeb("action \(action)")
            }

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
                if let text = payload?["url"] as? String,
                   let url = URL(string: text),
                   ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                   url.host != nil {
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

            case "getAppearance":
                reply(["action": "appearance", "payload": [
                    "theme": Self.storedAppearance,
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                ]])

            case "getProxy":
                reply(["action": "proxy", "payload": ["url": model.proxySubscription()]])

            case "setProxy":
                // Validated rather than trusted: what is stored ends up inside a
                // command the guest runs.
                if let url = payload?["url"] as? String,
                   let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                   ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
                   parsed.host != nil {
                    model.setProxySubscription(url)
                    reply(["action": "proxy", "payload": ["url": model.proxySubscription()]])
                }

            case "getModels":
                // The list lives in the guest's account, so this is a request to
                // ask it, not a cached read: the answer arrives later as a
                // `models` message.
                model.requestModels()
                model.pushModels()

            case "getAccount":
                // What the app already knows: the cached limits and conversation
                // list, so the frontend can draw them before the guest answers.
                model.pushAccount()
                model.pushModels()

            case "copy":
                // The device-code login is completed on another device, so the
                // code has to be able to leave the screen without being typed.
                if let text = payload?["text"] as? String, !text.isEmpty {
                    UIPasteboard.general.string = text
                }

            case "pickDisk":
                // A disk image cannot be chosen from inside a web view; the
                // frontend asks, the view presents the system picker.
                model.wantsDiskPicker = true

            case "setAppearance":
                // Validated rather than stored verbatim: the page is not the
                // authority on what the setting may be.
                guard let theme = payload?["theme"] as? String,
                      Self.appearances.contains(theme) else { return }
                UserDefaults.standard.set(theme, forKey: Self.appearanceKey)

            case "prompt":
                if let text = payload?["text"] as? String {
                    model.handlePrompt(text)
                }

            case "getAutomations":
                model.pushAutomations()

            case "saveAutomation":
                if let payload { model.upsertAutomation(payload) }

            case "deleteAutomation":
                if let id = payload?["id"] as? String { model.removeAutomation(id: id) }

            case "toggleAutomation":
                if let id = payload?["id"] as? String, let status = payload?["status"] as? String {
                    model.setAutomationStatus(id: id, status: status)
                }

            case "runAutomation":
                model.appendStatus("已请求立即运行该任务。")

            case "scheduleTask":
                if let text = payload?["text"] as? String {
                    model.upsertAutomation(["title": text, "cadence": "daily", "time": "22:00", "status": "active"])
                    model.appendStatus("已记录要安排的事，调度器接通后会按它执行。")
                }

            case "setModel":
                // The model, the reasoning level and the service tier for the
                // next prompt. Validated here so the guest is only ever asked
                // to run values from a known vocabulary.
                guard let payload else { return }
                var selection: [String: String] = [:]
                if let model = payload["model"] as? String, Self.isSafeToken(model) {
                    selection["model"] = model
                }
                if let effort = payload["effort"] as? String, Self.efforts.contains(effort) {
                    selection["effort"] = effort
                }
                if let speed = payload["speed"] as? String, Self.speeds.contains(speed) {
                    selection["speed"] = speed
                }
                UserDefaults.standard.set(selection, forKey: "pocketvm.model")

            case "pickFiles", "pickPhotos", "pickRemoteFile":
                model.appendStatus("此构建还没有接入系统选择器。")

            case "terminalInput":
                // The frontend sends base64 bytes; hand the guest exactly those.
                if let b64 = payload?["data"] as? String,
                   let data = Data(base64Encoded: b64) {
                    model.writeToConsole(data)
                }

            case "terminalReady", "terminalOpened":
                model.noteFromWeb(
                    "terminal \(action == "terminalOpened" ? "opened" : "ready") "
                        + "\(payload?["cols"] ?? "?")x\(payload?["rows"] ?? "?")"
                        + " pending \(payload?["pending"] ?? "-")"
                )

            case "terminalClosed":
                break

            case "note":
                // The page's own failures. A terminal that could not be built
                // is otherwise invisible from here.
                if let text = payload?["text"] as? String { model.noteFromWeb(text) }

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
            ) { [weak self] _, error in
                // A push that never lands is invisible otherwise: the page looks
                // idle and the only way to find out why is to say so.
                if let error {
                    self?.model.noteFromWeb(
                        "push \((object["action"] as? String) ?? "?") failed: \(error.localizedDescription)"
                    )
                }
            }
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
