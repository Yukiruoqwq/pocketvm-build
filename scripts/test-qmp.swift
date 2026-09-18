import Foundation

@main struct QMPTests {
    static func main() {
        var frames = QMPMessages()
        frames.append(Data("{\"QMP\":{}}\r\n{\"event\":\"RESUME\"}\r\n{\"id\":\"boot-status\",\"return\":{".utf8))
        precondition(frames.next()?["QMP"] != nil)
        precondition(frames.next()?["event"] as? String == "RESUME")
        precondition(frames.next() == nil)
        frames.append(Data("\"running\":true,\"status\":\"running\"}}\r\n".utf8))
        let reply = frames.next()!
        precondition(QMPMessages.running(reply, id: "boot-status"))
        precondition(!QMPMessages.running(reply, id: "other"))
        precondition(!QMPMessages.running(["id":"boot-status", "return":["running":false,"status":"paused"]], id: "boot-status"))
        precondition(!QMPMessages.running(["id":"boot-status", "error":["desc":"failed"]], id: "boot-status"))
        precondition(!QMPMessages.running(["event":"RESUME"], id: "boot-status"))
        print("PASS: split/coalesced QMP frames, response IDs, paused and failed states")
    }
}
