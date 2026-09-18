import Foundation

@main struct ChannelTests {
    @MainActor static func main() throws {
        let channel = CodexChannel()
        let epoch = UUID().uuidString
        var transitions: [Bool] = []
        var spawned = 0
        channel.onProcessStarted = { spawned += 1 }
        channel.onState = { ready, _ in transitions.append(ready) }
        func exchange(_ seq: Int? = nil, _ message: [String: Any] = [:], ready: Bool = true) throws -> [String: Any] {
            let events: [[String: Any]] = seq.map { [["seq": $0, "message": message]] } ?? []
            let packet: [String: Any] = ["version": 1, "epoch": epoch, "ready": ready, "spawned": true, "failure": NSNull(), "events": events]
            let data = channel.exchange(try JSONSerialization.data(withJSONObject: packet))!
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        _ = try exchange(ready: false)
        assert(spawned == 1 && transitions.isEmpty)
        _ = try exchange()
        assert(spawned == 1)
        assert(transitions == [true])
        var replies = 0
        channel.request("turn/start", ["threadId": "t"]) { _ in replies += 1 }
        let first = try exchange()["requests"] as! [[String: Any]]
        let again = try exchange()["requests"] as! [[String: Any]]
        assert(first[0]["id"] as! String == again[0]["id"] as! String)
        let response: [String: Any] = ["id": first[0]["id"]!, "result": [:]]
        _ = try exchange(1, response)
        _ = try exchange(1, response)
        assert(replies == 1)
        let empty = try exchange()["requests"] as! [[String: Any]]
        assert(empty.isEmpty)
        var events = 0
        channel.onEvent = { _ in events += 1 }
        _ = try exchange(2, ["method": "turn/completed", "params": [:]])
        _ = try exchange(2, ["method": "turn/completed", "params": [:]])
        assert(events == 1)
        _ = try exchange(ready: false)
        assert(transitions == [true, false])
        var rejected = false
        channel.request("turn/start") { rejected = $0["error"] != nil }
        assert(rejected)
        channel.reset()
        print("CodexChannel protocol tests passed")
    }
}
