import CryptoKit
import Foundation

/// A guest operating system image the app fetches on first use.
///
/// Nothing is bundled: a Debian cloud image is a third of a gigabyte, and the
/// IPA is handed to a sideloading tool that has to re-sign every byte. Pinning
/// a dated release URL together with its SHA-512 keeps a later rebuild on the
/// mirror from silently changing what the user boots.
struct GuestImage {
    let identifier: String
    let displayName: String
    let remoteURL: URL
    /// Lowercase hex, as published in Debian's SHA512SUMS.
    let sha512: String
    let fileName: String
    /// Size the disk is grown to before the guest's first boot.
    let capacityGiB: Int

    var localURL: URL {
        GuestImage.imagesDirectory.appendingPathComponent(fileName)
    }

    /// Everything QEMU needs to start this image's kernel without its firmware
    /// and without its boot loader.
    ///
    /// The two files are the image's own, copied out once, so the modules under
    /// `/lib/modules` inside the guest match the kernel exactly. Booting this
    /// way removes the only part of the machine that can stop and wait for a
    /// person: Debian's GRUB does that after an unclean shutdown, and a tablet
    /// has no keyboard to give it. It is also faster — the firmware and the boot
    /// loader never run — and the serial console is printing a second after
    /// power-on instead of twenty.
    struct DirectBoot {
        /// Relative to Documents/, the same way every other drive path is.
        let kernel: String
        let initrd: String
        let cmdline: String
    }

    var directBoot: DirectBoot {
        DirectBoot(
            kernel: "boot/vmlinuz-6.12.107+deb13-cloud-arm64",
            initrd: "boot/initrd.img-6.12.107+deb13-cloud-arm64",
            cmdline: "root=PARTUUID=\(rootPartUUID) ro console=ttyAMA0,115200"
        )
    }

    /// The root partition's UUID, as the image was built with it. It is what
    /// the kernel is told to mount when it is handed a command line instead of
    /// GRUB's own menu entry.
    var rootPartUUID: String { "51ebe23a-142a-4f1c-adb3-f4647ac4c9a7" }

    static var imagesDirectory: URL {
        let base = VMConfiguration.documentsDirectory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Debian trixie, the genericcloud flavour: an installed system with
    /// cloud-init and no desktop. The guest exists to run an agent, so every
    /// package that is not needed is emulated I/O the tablet pays for.
    static let debianCloudARM64 = GuestImage(
        identifier: "debian-13-genericcloud-arm64",
        displayName: "Debian 13 · aarch64",
        remoteURL: URL(
            string: "https://cloud.debian.org/images/cloud/trixie/20260914-2601/debian-13-genericcloud-arm64-20260914-2601.qcow2"
        )!,
        sha512: "9eeabc75e74a682fcaff785f6c1f6896b486159397201f51f58298a8f95990f6debb8058b6969ca95cf6823f6e8058dd6f8589ba940a194b2780cd7f95771d69",
        fileName: "debian-13-genericcloud-arm64.qcow2",
        capacityGiB: 24
    )
}

enum GuestImageError: Error, CustomStringConvertible {
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .downloadFailed(let reason):
            return "镜像下载失败：\(reason)"
        case .checksumMismatch(let expected, let actual):
            return "镜像校验失败：期望 \(expected.prefix(16))…，实际 \(actual.prefix(16))…"
        }
    }
}

/// Downloads guest images and verifies them before they are booted.
///
/// The download is a normal URLSession task, which gives progress, HTTP retry
/// and resume data for free. Verification streams the file through SHA-512
/// instead of loading it, because the file is larger than the memory the app
/// is allowed to allocate for a buffer.
final class GuestImageStore: NSObject {
    enum Event {
        case downloading(Double)
        case verifying(Double)
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var image: GuestImage?
    private var task: URLSessionDownloadTask?
    private var onEvent: ((Event) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var isRunning = false

    var running: Bool { isRunning }

    /// Verifies an existing file, then downloads it if it is missing or bad.
    func ensure(
        _ image: GuestImage,
        onEvent: @escaping (Event) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !isRunning else { return }
        self.image = image
        self.onEvent = onEvent
        self.onFinish = onFinish

        let destination = image.localURL
        if FileManager.default.fileExists(atPath: destination.path) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let digest = try? GuestImageStore.sha512Hex(of: destination) { fraction in
                    DispatchQueue.main.async { self?.onEvent?(.verifying(fraction)) }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if digest == image.sha512 {
                        self.finish(.success(destination))
                    } else {
                        // A truncated file from an interrupted session is the
                        // common case here, so discard it and fetch again.
                        try? FileManager.default.removeItem(at: destination)
                        self.beginDownload(image)
                    }
                }
            }
        } else {
            beginDownload(image)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func beginDownload(_ image: GuestImage) {
        isRunning = true
        let request = URLRequest(url: image.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData)
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    private func finish(_ result: Result<URL, Error>) {
        let delivery = { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.task = nil
            let callback = self.onFinish
            self.onFinish = nil
            self.onEvent = nil
            callback?(result)
        }
        if Thread.isMainThread { delivery() } else { DispatchQueue.main.async(execute: delivery) }
    }

    /// Everything the owner sees arrives on the main queue: the callbacks land
    /// in a `@MainActor` state machine, and URLSession's delegate queue is not it.
    private func emit(_ event: Event) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    /// Streaming SHA-512 so a 300 MB image never has to be in memory at once.
    static func sha512Hex(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0

        var hasher = SHA512()
        var consumed = 0.0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            consumed += Double(chunk.count)
            if total > 0 { progress?(consumed / total) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension GuestImageStore: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        emit(.downloading(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let image else { return }
        let staging = image.localURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            finish(.failure(GuestImageError.downloadFailed("\(error)")))
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let digest = try? GuestImageStore.sha512Hex(of: staging) { fraction in
                self?.emit(.verifying(fraction))
            }
            self?.stageVerifiedDownload(staging: staging, image: image, digest: digest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(GuestImageError.downloadFailed(error.localizedDescription)))
    }
}

extension GuestImageStore {
    /// Moves a verified download into place, or reports why it cannot be used.
    fileprivate func stageVerifiedDownload(staging: URL, image: GuestImage, digest: String?) {
        let settle = { [weak self] in
            guard let self else { return }
            guard digest == image.sha512 else {
                try? FileManager.default.removeItem(at: staging)
                self.finish(.failure(GuestImageError.checksumMismatch(expected: image.sha512, actual: digest ?? "?")))
                return
            }
            do {
                try? FileManager.default.removeItem(at: image.localURL)
                try FileManager.default.moveItem(at: staging, to: image.localURL)
                self.finish(.success(image.localURL))
            } catch {
                self.finish(.failure(error))
            }
        }
        if Thread.isMainThread { settle() } else { DispatchQueue.main.async(execute: settle) }
    }
}
