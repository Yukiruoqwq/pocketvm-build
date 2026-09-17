import Foundation

/// QEMU's translator emits machine code, which needs writable and executable
/// pages. iOS refuses that for a sideloaded build: the `dynamic-codesigning`
/// entitlement is not obtainable with a free Apple ID, and unlike the memory
/// entitlements there is no legitimate way to request it.
///
/// A debugger being attached changes the kernel's answer. `csops` then reports
/// `CS_DEBUGGED`, and the allocation succeeds. That is the entire reason
/// StikDebug has to attach before the VM starts.
enum JIT {
    private static let csOpsStatus: UInt32 = 0
    /// Bit reported by `csops(CS_OPS_STATUS)` once a debugger is attached.
    /// Confirmed against this device: 0x32003005 with a debugger versus
    /// 0x22003305 without differs by exactly this bit.
    private static let csDebugged: UInt32 = 0x1000_0000

    @_silgen_name("csops")
    private static func csops(
        _ pid: pid_t,
        _ ops: UInt32,
        _ useraddr: UnsafeMutableRawPointer?,
        _ usersize: Int
    ) -> Int32

    static func statusFlags() -> UInt32? {
        var flags: UInt32 = 0
        let result = withUnsafeMutablePointer(to: &flags) { pointer in
            csops(getpid(), csOpsStatus, UnsafeMutableRawPointer(pointer), MemoryLayout<UInt32>.size)
        }
        return result == 0 ? flags : nil
    }

    public static var isDebugged: Bool {
        guard let flags = statusFlags() else { return false }
        return flags & csDebugged != 0
    }

    public static var explanation: String {
        if let flags = statusFlags() {
            return String(format: "csops flags 0x%08x, debugger %@", flags, isDebugged ? "attached" : "not attached")
        }
        return "csops unavailable"
    }
}
