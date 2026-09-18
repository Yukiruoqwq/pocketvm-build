import Foundation

/// Host messages, also written to Documents.
///
/// The in-app log is only readable while the app is alive, and the failures that
/// matter here kill the process outright — an emulator that cannot start, or a
/// translation buffer iOS refuses. Documents is reachable over a cable, so the
/// last thing that happened survives the crash.
final class HostLog {
    private let url: URL
    private let queue = DispatchQueue(label: "com.pocketvm.host-log")
    private let limit = 1 << 20

    init() {
        url = VMConfiguration.documentsDirectory.appendingPathComponent("pocketvm.log")
    }

    func write(_ line: String) {
        let entry = "\(HostLog.stamp()) \(line)\n"
        queue.async { [url, limit] in
            let manager = FileManager.default
            let existing = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if existing > limit {
                // Keep the tail: the interesting part is always the end.
                if let data = try? Data(contentsOf: url), data.count > limit / 2 {
                    try? data.suffix(limit / 2).write(to: url, options: .atomic)
                }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? Data(entry.utf8).write(to: url)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
