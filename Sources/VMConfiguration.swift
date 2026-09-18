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
    ///
    /// 256 MiB is what UTM's own configuration for this device uses; the
    /// translation cache is resident memory the guest cannot have, so the
    /// default stays at the value that is known to fit.
    var jitCacheMiB: Int = 256
    /// Lets the translator use more than one host thread. UTM leaves this off
    /// by default on iOS and calls it experimental there.
    var forceMulticore: Bool = false
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
        copy.name = String(copy.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if copy.name.isEmpty { copy.name = "VM" }
        copy.cpuCount = min(max(copy.cpuCount, 1), 16)
        // iOS refuses large allocations long before the hardware runs out, and
        // a refusal inside the emulator is much harder to read than a clamp.
        copy.memoryMiB = min(max(copy.memoryMiB, 256), 8192)
        copy.jitCacheMiB = min(max(copy.jitCacheMiB, 16), 4096)
        copy.boot.kernel = Self.safeRelativePath(copy.boot.kernel)
        copy.boot.initrd = Self.safeRelativePath(copy.boot.initrd)
        copy.drives = copy.drives.compactMap { drive in
            guard let path = Self.safeRelativePath(drive.path), !path.isEmpty else { return nil }
            var drive = drive
            drive.path = path
            if let format = drive.format?.lowercased(), ["raw", "qcow2", "vmdk", "vdi"].contains(format) {
                drive.format = format
            } else {
                drive.format = nil
            }
            if let node = drive.nodeName,
               !node.isEmpty, node.count <= 64,
               node.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) {
                drive.nodeName = node
            } else {
                drive.nodeName = nil
            }
            return drive
        }
        copy.network.portForwards = copy.network.portForwards.compactMap { forward in
            guard (1...65535).contains(forward.hostPort),
                  (1...65535).contains(forward.guestPort),
                  ["tcp", "udp"].contains(forward.protocolName.lowercased()) else { return nil }
            var forward = forward
            forward.protocolName = forward.protocolName.lowercased()
            return forward
        }
        return copy
    }

    private static func safeRelativePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains(":"), !trimmed.contains(","),
              !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty,
              !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
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
