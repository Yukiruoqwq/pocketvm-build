import Foundation

/// Typed envelopes over the guest HTTP transport; terminal output is not input.
@MainActor
final class CodexChannel {
    var onState: ((Bool, String?) -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    private var epoch: String?
    private var ack = 0
    private var ready = false
    private var lastSeen = Date.distantPast
    private var requests: [[String: Any]] = []
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var deadlines: [String: Date] = [:]
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func reset() {
        ready = false; epoch = nil; ack = 0; requests.removeAll()
        let pending = Array(callbacks.values); callbacks.removeAll(); deadlines.removeAll()
        for callback in pending { callback(["error": ["message": "连接已断开；未自动重发请求"]]) }
    }
    func request(_ method: String, _ params: [String: Any] = [:], callback: @escaping ([String: Any]) -> Void) {
        guard ready else { callback(["error": ["message": "Codex 服务未连接"]]); return }
        let id = UUID().uuidString
        callbacks[id] = callback; deadlines[id] = Date().addingTimeInterval(90)
        requests.append(["id": id, "method": method, "params": params])
    }
    func exchange(_ data: Data) -> Data? {
        guard let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              packet["version"] as? Int == 1, let incoming = packet["epoch"] as? String,
              UUID(uuidString: incoming) != nil, let isReady = packet["ready"] as? Bool else { return nil }
        if epoch != incoming { reset(); epoch = incoming }
        lastSeen = Date()
        if ready != isReady {
            ready = isReady
            onState?(ready, ready ? nil : "Codex 服务正在重连")
        }
        if let failure = packet["failure"] as? [String: Any] {
            onState?(false, "Codex 服务错误：\(failure["kind"] ?? "unknown")")
        }
        for event in packet["events"] as? [[String: Any]] ?? [] {
            guard let seq = event["seq"] as? Int, seq > ack,
                  seq == ack + 1, let message = event["message"] as? [String: Any] else { continue }
            ack = seq
            if let id = message["id"] as? String, let callback = callbacks.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id); requests.removeAll { $0["id"] as? String == id }
                callback(message)
            } else if message["id"] != nil, message["method"] != nil {
                // Approval/tool requests cannot silently grant authority.
                requests.append(["id": message["id"]!, "error": ["code": -32601, "message": "此客户端尚不支持此交互请求"]])
            } else { onEvent?(message) }
        }
        let reply: [String: Any] = ["epoch": incoming, "ack": ack, "requests": Array(requests.prefix(64))]
        requests.removeAll { $0["error"] != nil }
        return try? JSONSerialization.data(withJSONObject: reply)
    }
    private func tick() {
        if ready && Date().timeIntervalSince(lastSeen) > 12 {
            reset(); onState?(false, "与 Codex 服务的连接已中断")
        }
        for (id, deadline) in Array(deadlines) where deadline < Date() {
            deadlines.removeValue(forKey: id); requests.removeAll { $0["id"] as? String == id }
            callbacks.removeValue(forKey: id)?(["error": ["message": "请求超时，执行状态未知；未自动重试"]])
        }
    }
}
