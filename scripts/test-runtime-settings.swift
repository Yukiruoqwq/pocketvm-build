import Foundation

@main struct RuntimeSettingsTests {
    static func main() throws {
        let legacy = VMConfiguration()
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)
        precondition(decoded.sshForward == nil)
        var config = decoded
        config.developerSSH = true
        config.developerSSHPort = 8474
        config.network.enabled = false
        config.network.portForwards = [.init(hostPort: 2222, guestPort: 80)]
        config = config.validated()
        precondition(config.network.enabled)
        precondition(config.sshForward == "tcp:127.0.0.1:2222-:22")
        precondition(config.network.portForwards.isEmpty)
        config.developerSSH = false
        precondition(config.sshForward == nil)
        precondition(ExecutionMode.select(jitAvailable: false) == .interpreter)
        precondition(ExecutionMode.select(jitAvailable: true) == .jit)
        let slow = ExecutionMode.interpreter.accelerator(cacheMiB: 256, multicore: true)
        precondition(slow == "tcg,thread=single,tb-size=256")
        precondition(ExecutionMode.jit.accelerator(cacheMiB: 256, multicore: true).contains("split-wx=on"))
        print("PASS: legacy config, SSH isolation/conflicts, JIT and interpreter selection")
    }
}
