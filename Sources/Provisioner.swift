import Foundation

/// Persisted record of the one-time guest setup.
///
/// Kept beside the image rather than inside `pocketvm.json` so that editing VM
/// settings from the frontend can never accidentally re-trigger provisioning or
/// forget that it already happened.
struct ProvisionState: Codable {
    var imageIdentifier: String = GuestImage.debianCloudARM64.identifier
    var completed: Bool = false
    var completedAt: Date?
    /// The qcow2 has been grown to the requested capacity.
    var capacityApplied: Bool = false
    var password: String = ProvisionState.makePassword()
    var instanceID: String = UUID().uuidString.lowercased()

    static var url: URL {
        VMConfiguration.documentsDirectory.appendingPathComponent("provision.json")
    }

    static func load() -> ProvisionState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ProvisionState.self, from: data) else {
            return ProvisionState()
        }
        return state
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: ProvisionState.url, options: .atomic)
    }

    /// Six digits: the login is for a serial console the device owner is already
    /// holding, and a password nobody can dictate over a cable is worse than a
    /// short one that is displayed in the app.
    static func makePassword() -> String {
        String(format: "%06d", Int.random(in: 100000...999999))
    }
}

/// Drives the first boot of the guest.
///
/// The app ships no disk image, so the first run has to fetch one, tell
/// cloud-init what to do with it, and then watch the guest work. All of that is
/// reported to the frontend as a stage, and the guest reports its own progress
/// on the serial console, which is the same stream the terminal shows.
@MainActor
final class Provisioner: ObservableObject {
    enum Stage: Equatable {
        case idle
        case downloading(Double)
        case verifying(Double)
        case preparing
        case booting
        /// A progress line echoed by the guest while it installs packages.
        case installing(String)
        case ready
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .verifying, .preparing, .booting, .installing: return true
            case .idle, .ready, .failed: return false
            }
        }

        var description: String {
            switch self {
            case .idle: return "未准备"
            case .downloading(let fraction): return "下载镜像 \(Int(fraction * 100))%"
            case .verifying(let fraction): return "校验镜像 \(Int(fraction * 100))%"
            case .preparing: return "准备启动参数"
            case .booting: return "首次启动，等待客户机"
            case .installing(let line): return line
            case .ready: return "准备完成"
            case .failed(let reason): return "失败：\(reason)"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var state: ProvisionState

    let image = GuestImage.debianCloudARM64
    private let store = GuestImageStore()
    private var server: SeedServer?
    private var lineBuffer = ""

    /// Set when the guest reports that it finished; the caller uses it to drop
    /// the seed arguments from the next boot.
    var onFinished: ((ProvisionState) -> Void)?
    var onLog: ((String) -> Void)?

    init() {
        state = ProvisionState.load()
        if state.completed {
            stage = .ready
        }
        if state.imageIdentifier != image.identifier {
            // A build that points at a different image has nothing to say about
            // the previous one's completion.
            state.completed = false
            state.imageIdentifier = image.identifier
            stage = .idle
        }
    }

    var isProvisioned: Bool { state.completed }

    /// Fetches whatever is missing and returns the boot profile for first boot.
    func prepare() async throws -> (configuration: VMConfiguration, profile: QEMUHost.BootProfile) {
        if !state.completed {
            if !FileManager.default.fileExists(atPath: image.localURL.path) {
                _ = try await ensureImage()
            } else {
                stage = .verifying(0)
                do {
                    try await verifyExisting()
                } catch {
                    stage = .downloading(0)
                    _ = try await ensureImage()
                }
            }
        }

        stage = .preparing
        excludeFromBackup()
        try installUEFIVariables()
        var configuration = try VMConfiguration.loadOrCreateDefault()
        configuration.drives = defaultDrives(existing: configuration)
        configuration.name = "Debian 13 · aarch64"
        configuration.boot = VMConfiguration.Boot(mode: .uefi)
        configuration = configuration.validated()
        try configuration.write()

        // The seed only matters on the first boot, but leaving it in place is
        // harmless and it makes a retry work without a second code path.
        let profile = try makeBootProfile()
        stage = .booting
        return (configuration, profile)
    }

    /// Feeds one line of guest console output through the state machine.
    func ingest(consoleLine line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let message = trimmed.range(of: "POCKETVM:") {
            let text = String(trimmed[message.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                stage = .installing(text)
                onLog?("guest: \(text)")
            }
            return
        }
        if trimmed.contains("POCKETVM_READY") {
            markProvisioned()
            return
        }
        if trimmed.contains("POCKETVM_FAILED") {
            stage = .failed("客户机报告安装失败，可在终端里查看 /var/log/pocketvm-provision.log")
            return
        }
    }

    func markProvisioned() {
        guard !state.completed else { return }
        state.completed = true
        state.completedAt = Date()
        state.write()
        stage = .ready
        server?.stop()
        server = nil
        onLog?("guest reported provisioning complete")
        onFinished?(state)
    }

    func reset() {
        server?.stop()
        server = nil
        state = ProvisionState()
        state.write()
        stage = .idle
    }

    // MARK: - Image

    private func ensureImage() async throws -> URL {
        let image = self.image
        return try await withCheckedThrowingContinuation { continuation in
            store.ensure(image, onEvent: { [weak self] event in
                switch event {
                case .downloading(let fraction): self?.stage = .downloading(fraction)
                case .verifying(let fraction): self?.stage = .verifying(fraction)
                }
            }, onFinish: { result in
                continuation.resume(with: result)
            })
        }
    }

    private func verifyExisting() async throws {
        let url = image.localURL
        let expected = image.sha512
        let digest = try await Task.detached(priority: .utility) { [weak self] () -> String in
            try GuestImageStore.sha512Hex(of: url) { fraction in
                Task { @MainActor in self?.stage = .verifying(fraction) }
            }
        }.value
        guard digest == expected else {
            throw GuestImageError.checksumMismatch(expected: expected, actual: digest)
        }
    }

    // MARK: - Firmware

    /// The guest disk is tens of gigabytes of sparse file that iOS would happily
    /// try to back up. Nothing in it is worth backing up: it can be rebuilt from
    /// the image, and the image can be re-downloaded.
    private func excludeFromBackup() {
        var url = GuestImage.imagesDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// UTM uses the ARM variable-store template for aarch64 as well; the
    /// aarch64 image ships code only. The guest writes boot entries into this
    /// file, so it lives in Documents next to the disk.
    private func installUEFIVariables() throws {
        let destination = VMConfiguration.documentsDirectory.appendingPathComponent("efi_vars.fd")
        if FileManager.default.fileExists(atPath: destination.path) { return }
        guard let template = Bundle.main.url(forResource: "edk2-arm-vars", withExtension: "fd", subdirectory: "qemu") else {
            throw VMConfigurationError.missingFile("qemu/edk2-arm-vars.fd")
        }
        try FileManager.default.copyItem(at: template, to: destination)
    }

    private func defaultDrives(existing: VMConfiguration) -> [VMConfiguration.Drive] {
        var drives: [VMConfiguration.Drive] = [
            VMConfiguration.Drive(
                path: "efi_vars.fd",
                interface: .pflash,
                readOnly: false
            ),
            VMConfiguration.Drive(
                path: "Images/\(image.fileName)",
                interface: .virtio,
                readOnly: false,
                format: "qcow2",
                nodeName: "root"
            ),
        ]
        // Keep drives the user added beyond the two we manage.
        for drive in existing.drives where drive.interface != .pflash && drive.nodeName != "root" {
            if !drives.contains(where: { $0.path == drive.path }) { drives.append(drive) }
        }
        return drives
    }

    // MARK: - Seed

    private func makeBootProfile() throws -> QEMUHost.BootProfile {
        var profile = QEMUHost.BootProfile()
        if !state.completed {
            let server = try SeedServer(preferredPort: 0)
            server.onLog = { [weak self] line in
                self?.onLog?("seed: \(line)")
            }
            server.onRequest = { [weak self] path in
                self?.onLog?("seed: guest asked for \(path)")
            }
            try server.start(resources: [
                "/meta-data": .yaml(metadata()),
                "/user-data": .yaml(userData()),
                "/vendor-data": .text("#cloud-config\n"),
            ])
            self.server = server
            profile.extraArguments = [
                // cloud-init reads the NoCloud data source URL from the SMBIOS
                // serial number; SLIRP resolves 10.0.2.2 to the host loopback
                // where the seed server is listening.
                "-smbios", "type=1,serial=ds=nocloud-net;s=http://10.0.2.2:\(server.port)/",
            ]
        }
        if !state.capacityApplied {
            profile.resize = QEMUHost.BootProfile.Resize(node: "root", sizeGiB: image.capacityGiB)
        }
        return profile
    }

    private func metadata() -> String {
        """
        instance-id: \(state.instanceID)
        local-hostname: pocketvm
        """
    }

    /// cloud-init configuration for the first boot.
    ///
    /// The guest is expected to come up talking to its own serial port: that is
    /// the only console the app has, so both the login prompt and the progress
    /// reports are written to it explicitly rather than being left to whatever
    /// the distribution decides a console is.
    private func userData() -> String {
        """
        #cloud-config
        hostname: pocketvm
        manage_etc_hosts: true
        ssh_pwauth: true
        users:
          - name: codex
            gecos: Codex
            groups: [adm, sudo, dialout]
            shell: /bin/bash
            sudo: "ALL=(ALL) NOPASSWD:ALL"
            lock_passwd: false
        chpasswd:
          expire: false
          list: |
            codex:\(state.password)
            root:\(state.password)
        write_files:
          - path: /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf
            permissions: '0644'
            content: |
              [Service]
              ExecStart=
              ExecStart=-/sbin/agetty --autologin codex --keep-baud 115200,38400,9600 %I $TERM
          - path: /usr/local/sbin/pocketvm-provision.sh
            permissions: '0755'
            content: |
        \(indent(provisionScript(), spaces: 6))
          - path: /usr/local/sbin/pocketvm-auth
            permissions: '0755'
            content: |
        \(indent(authScript(), spaces: 6))
        runcmd:
          - systemctl daemon-reload
          - systemctl enable --now serial-getty@ttyAMA0.service
          - /usr/local/sbin/pocketvm-provision.sh
        """
    }

    /// The guest side of the sign-in flow.
    ///
    /// The host app is the only terminal the user has, so the login has to run
    /// in the background with its output on disk, and the state has to come back
    /// as a couple of fixed lines rather than as a redrawn TUI.
    private func authScript() -> String {
        """
        #!/bin/bash
        # Written by PocketVM. Prints a fixed vocabulary the host parses.
        LOG=/tmp/pocketvm-login.log

        if [ "${1:-status}" = "start" ]; then
          rm -f "$LOG"
          nohup codex login --device-auth >"$LOG" 2>&1 </dev/null &
          sleep 2
        fi

        if codex login status 2>/dev/null | grep -qi "not logged in"; then
          echo POCKETVM_AUTH_STATE not_logged_in
        elif codex login status 2>/dev/null | grep -qi "logged in"; then
          echo POCKETVM_AUTH_STATE logged_in
        else
          echo POCKETVM_AUTH_STATE unknown
        fi

        if [ -s "$LOG" ]; then
          tail -n 30 "$LOG" | tr -d '\\r'
        fi
        """
    }

    /// Runs inside the guest on first boot.
    ///
    /// Every step is emulated aarch64, so the script is deliberately small and
    /// keeps its noisy output in a log file while sending one readable line per
    /// step to the serial console for the app to display.
    private func provisionScript() -> String {
        """
        #!/bin/bash
        # Written by PocketVM. Safe to re-run: every step is idempotent.
        set -u
        TTY=/dev/ttyAMA0
        LOG=/var/log/pocketvm-provision.log
        say() { printf 'POCKETVM: %s\\n' "$*" > "$TTY" 2>/dev/null || true; }

        say "扩容根分区"
        ROOTDEV="$(findmnt -no SOURCE /)"
        PART="$(printf '%s' "$ROOTDEV" | sed -n 's/.*[^0-9]\\([0-9][0-9]*\\)$/\\1/p')"
        DISK="$(printf '%s' "$ROOTDEV" | sed -n 's/\\(.*[^0-9]\\)[0-9][0-9]*$/\\1/p')"
        if [ -n "$PART" ] && [ -n "$DISK" ] && [ "$PART" != "$DISK" ]; then
          partprobe "$DISK" >/dev/null 2>&1 || true
          growpart "$DISK" "$PART" >/dev/null 2>&1 || true
          resize2fs "$ROOTDEV" >/dev/null 2>&1 || true
        fi
        say "根分区 $(df -h / | awk 'NR==2 {print $2}')"

        export DEBIAN_FRONTEND=noninteractive
        say "更新软件源"
        apt-get update -qq >>"$LOG" 2>&1 || say "软件源更新失败，稍后可在终端重试"

        say "安装基础软件"
        apt-get install -y -qq --no-install-recommends \\
          curl ca-certificates git jq nodejs npm >>"$LOG" 2>&1 \\
          || say "基础软件安装失败，稍后可在终端重试"

        if ! command -v node >/dev/null 2>&1; then
          say "改用 NodeSource 安装 Node"
          curl -fsSL https://deb.nodesource.com/setup_22.x 2>>"$LOG" | bash - >>"$LOG" 2>&1 || true
          apt-get install -y -qq nodejs >>"$LOG" 2>&1 || true
        fi
        say "Node $(node --version 2>/dev/null || echo 未安装)"

        if ! command -v codex >/dev/null 2>&1; then
          say "安装 Codex CLI"
          npm install -g --no-fund --no-audit @openai/codex >>"$LOG" 2>&1 || say "Codex 安装失败，可在终端手动重试"
        fi

        if command -v codex >/dev/null 2>&1; then
          say "Codex $(codex --version 2>/dev/null | head -n 1)"
          echo POCKETVM_READY >"$TTY"
        else
          say "安装未完成"
          echo POCKETVM_FAILED >"$TTY"
        fi
        """
    }

    private func indent(_ text: String, spaces: Int) -> String {
        let padding = String(repeating: " ", count: spaces)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : padding + $0 }
            .joined(separator: "\n")
    }
}
