import Foundation

struct BootProgress {
    enum Phase: Int {
        case qemu, system, codex, ready
        var code: String { ["qemu", "system", "codex", "ready"][rawValue] }
        var detail: String { ["正在启动 QEMU", "正在引导系统", "正在启动 Codex CLI", ""][rawValue] }
    }
    private(set) var phase: Phase = .qemu
    mutating func advance(to next: Phase) {
        if next.rawValue > phase.rawValue { phase = next }
    }
}
