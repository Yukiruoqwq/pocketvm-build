import Foundation

enum ExecutionMode: String {
    case jit, interpreter

    static func select(jitAvailable: Bool) -> ExecutionMode {
        jitAvailable ? .jit : .interpreter
    }

    var frameworkName: String {
        self == .jit ? "qemu-aarch64-softmmu" : "tciu-aarch64-softmmu"
    }

    func accelerator(cacheMiB: Int, multicore: Bool) -> String {
        if self == .interpreter { return "tcg,thread=single,tb-size=\(cacheMiB)" }
        return "tcg,thread=\(multicore ? "multi" : "single"),tb-size=\(cacheMiB),split-wx=on"
    }
}
