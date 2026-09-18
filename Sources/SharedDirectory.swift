import Foundation
import Darwin

/// Exports only Documents/Shared, never host credentials or VM disks.
final class SharedDirectory {
    static var root: URL { VMConfiguration.documentsDirectory.appendingPathComponent("Shared", isDirectory: true) }
    let root: URL
    init(root: URL = SharedDirectory.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }
    private func resolve(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !path.contains("\0") else { throw Failure(13) }
        var url = root
        for part in components {
            url.appendPathComponent(String(part))
            if (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw Failure(13) }
        }
        guard url.standardizedFileURL.path == root.path || url.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw Failure(13) }
        return url
    }
    struct Failure: Error { let number: Int; init(_ number: Int) { self.number = number } }
    func exchange(_ data: Data) -> Data? {
        var reply: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = request["op"] as? String, let path = request["path"] as? String else { throw Failure(22) }
            let url = try resolve(path), fm = FileManager.default
            var value: Any = 0
            let offset = request["offset"] as? Int ?? 0
            let size = request["size"] as? Int ?? 0
            guard offset >= 0, size >= 0 else { throw Failure(22) }
            if ["unlink", "rmdir", "rename", "truncate", "write", "create"].contains(op), url == root { throw Failure(13) }
            switch op {
            case "stat":
                let a = try fm.attributesOfItem(atPath: url.path)
                let directory = a[.type] as? FileAttributeType == .typeDirectory
                value = ["st_mode": directory ? 0o40755 : 0o100644, "st_nlink": directory ? 2 : 1,
                         "st_size": (a[.size] as? NSNumber)?.intValue ?? 0,
                         "st_mtime": (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0]
            case "list": value = try fm.contentsOfDirectory(atPath: url.path)
            case "read":
                guard size <= 262144 else { throw Failure(22) }
                let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
                try f.seek(toOffset: UInt64(offset)); value = (try f.read(upToCount: size) ?? Data()).base64EncodedString()
            case "write":
                guard let encoded = request["data"] as? String, let bytes = Data(base64Encoded: encoded), bytes.count <= 262144 else { throw Failure(22) }
                let f = try FileHandle(forWritingTo: url); defer { try? f.close() }
                try f.seek(toOffset: UInt64(offset)); try f.write(contentsOf: bytes); try f.synchronize(); value = bytes.count
            case "create":
                guard !fm.fileExists(atPath: url.path) else { throw Failure(17) }
                try Data().write(to: url, options: .withoutOverwriting)
            case "truncate":
                let f = try FileHandle(forWritingTo: url); defer { try? f.close() }; try f.truncate(atOffset: UInt64(size))
            case "mkdir": try fm.createDirectory(at: url, withIntermediateDirectories: false)
            case "unlink", "rmdir":
                let a = try fm.attributesOfItem(atPath: url.path)
                let directory = a[.type] as? FileAttributeType == .typeDirectory
                guard directory == (op == "rmdir") else { throw Failure(directory ? 21 : 20) }
                if directory, !(try fm.contentsOfDirectory(atPath: url.path)).isEmpty { throw Failure(39) }
                try fm.removeItem(at: url)
            case "rename":
                guard let target = request["target"] as? String else { throw Failure(22) }
                let dest = try resolve(target); guard dest != root else { throw Failure(13) }
                guard Darwin.rename(url.path, dest.path) == 0 else { throw Failure(5) }
            default: throw Failure(38)
            }
            reply = ["result": value]
        } catch let failure as Failure { reply = ["errno": failure.number] }
        catch {
            let e = error as NSError
            reply = ["errno": [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code) ? 2 : (e.code == NSFileWriteFileExistsError ? 17 : 5)]
        }
        return try? JSONSerialization.data(withJSONObject: reply)
    }
}
