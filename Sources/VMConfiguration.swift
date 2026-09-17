import Foundation

/// On-disk description of a virtual machine.
///
/// This type is the contract between the app and whatever frontend drives it
/// later, so it stays plain JSON with an explicit version rather than
/// mirroring an internal object graph.
struct VMConfiguration: Codable, Equatable {
    static let currentVersion = 1

    enum BootMode: String, Codable, Equatable {
        /// Boot the firmware in `qemu/`, then let the guest's own bootloader run.
        case uefi
        /// Boot a kernel directly, bypassing firmware and any bootloader.
        case direct
    }

    struct Boot: Codable, Equatable {
        var mode: BootMode = .uefi
        /// Paths relative to Documents/, used when `mode` is `.direct`.
        var kernel: String?
        var initrd: String?
        var cmdline: String?
    }

    enum DriveInterface: String, Codable, Equatable {
        case virtio
        case pflash
        case usb
    }

    struct Drive: Codable, Equatable {
        var path: String
        var interface: DriveInterface = .virtio
        var readOnly: Bool = false
        /// Raw images must be declared as such; qcow2 is detected otherwise.
        var format: String?
        /// Names the block node when the drive has to be addressed by QMP,
        /// which is how the disk is grown before the guest reads its partition
        /// table on the first boot.
        var nodeName: String?
    }

    struct PortForward: Codable, Equatable {
        var hostPort: Int
        var guestPort: Int
        var protocolName: String = "tcp"
    }

    struct Network: Codable, Equatable {
        var enabled: Bool = true
        var portForwards: [PortForward] = []
    }

    var version: Int = VMConfiguration.currentVersion
    var name: String = "VM"
    var cpuCount: Int = 4
    var memoryMiB: Int = 4096
    /// Translation cache for the emulator. Larger avoids retranslation at the
    /// cost of resident memory.
    var jitCacheMiB: Int = 512
    /// Lets the translator use more than one host thread.
    var forceMulticore: Bool = true
    var boot: Boot = Boot()
    var drives: [Drive] = []
    var network: Network = Network()

    static var defaultURL: URL {
        documentsDirectory.appendingPathComponent("pocketvm.json")
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func loadOrCreateDefault() throws -> VMConfiguration {
        let url = defaultURL
        if let data = try? Data(contentsOf: url) {
            let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)
            guard decoded.version <= currentVersion else {
                throw VMConfigurationError.unsupportedVersion(decoded.version)
            }
            return decoded
        }
        let fresh = VMConfiguration()
        try fresh.write()
        return fresh
    }

    func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: VMConfiguration.defaultURL, options: .atomic)
    }

    /// Clamp values that would otherwise make QEMU fail in a confusing way.
    func validated() -> VMConfiguration {
        var copy = self
        copy.cpuCount = min(max(copy.cpuCount, 1), 16)
        // iOS refuses large allocations long before the hardware runs out, and
        // a refusal inside the emulator is much harder to read than a clamp.
        copy.memoryMiB = min(max(copy.memoryMiB, 256), 8192)
        copy.jitCacheMiB = min(max(copy.jitCacheMiB, 16), 4096)
        return copy
    }
}

enum VMConfigurationError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)
    case missingFile(String)

    var description: String {
        switch self {
        case .unsupportedVersion(let v):
            return "Configuration version \(v) is newer than this build understands."
        case .missingFile(let p):
            return "Required file is missing: \(p)"
        }
    }
}
