import Foundation

/// QMP can deliver multiple JSON frames in one socket read, or split one frame.
struct QMPMessages {
    private var buffer = Data()
    mutating func append(_ data: Data) { buffer.append(data) }
    mutating func next() -> [String: Any]? {
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return value }
        }
        return nil
    }
    static func running(_ reply: [String: Any], id: String) -> Bool {
        guard reply["id"] as? String == id,
              let result = reply["return"] as? [String: Any] else { return false }
        return result["running"] as? Bool == true && result["status"] as? String == "running"
    }
}
