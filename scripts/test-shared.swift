import Foundation

@main struct Tests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try SharedDirectory(root: root)
        func check(_ condition: Bool) { precondition(condition) }
        func call(_ op: String, _ path: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
            var request = fields; request["op"] = op; request["path"] = path
            return try JSONSerialization.jsonObject(with: shared.exchange(JSONSerialization.data(withJSONObject: request))!) as! [String: Any]
        }
        check(try call("create", "/example.txt")["errno"] == nil)
        let contents = Data("hello 世界".utf8)
        check(try call("write", "/example.txt", ["data": contents.base64EncodedString(), "offset": 0])["result"] as? Int == contents.count)
        check(try call("read", "/example.txt", ["offset": 0, "size": 100])["result"] as? String == contents.base64EncodedString())
        check(try call("rename", "/example.txt", ["target": "/renamed.txt"])["errno"] == nil)
        check(try call("stat", "/example.txt")["errno"] as? Int == 2)
        check(try call("stat", "/../provision.json")["errno"] as? Int == 13)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        check(try call("list", "/escape")["errno"] as? Int == 13)
        check(try call("rmdir", "/")["errno"] as? Int == 13)
        check(try call("read", "/renamed.txt", ["offset": -1, "size": 10])["errno"] as? Int == 22)
        check(try call("read", "/renamed.txt", ["size": 1_000_000])["errno"] as? Int == 22)
        check(try call("unlink", "/renamed.txt")["errno"] == nil)
        print("Shared directory: read/write/rename, traversal, symlink and size limits passed")
    }
}
