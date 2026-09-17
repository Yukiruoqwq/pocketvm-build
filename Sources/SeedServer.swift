import Foundation
import Network

/// Serves cloud-init's NoCloud seed to the guest over the emulated network.
///
/// QEMU's user-mode networking makes the guest's `10.0.2.2` an alias for the
/// host's loopback, so a listener bound to `127.0.0.1` is reachable from inside
/// the guest with no port forwarding and without tripping iOS's local network
/// permission prompt, which only covers non-loopback listeners.
///
/// The routes are plain in-memory resources: the seed is a handful of kilobytes
/// of YAML generated at boot, and writing it to a filesystem would need an
/// extra drive just to hold it.
final class SeedServer {
    struct Resource {
        let contentType: String
        let body: Data

        static func yaml(_ text: String) -> Resource {
            Resource(contentType: "text/yaml", body: Data(text.utf8))
        }

        static func text(_ text: String) -> Resource {
            Resource(contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.pocketvm.seed-server")
    private var resources: [String: Resource] = [:]
    private var started = false

    /// Port the listener actually bound, available after `start`.
    private(set) var port: UInt16 = 0
    var onLog: ((String) -> Void)?
    /// Called with each requested path, so the host log shows whether the guest
    /// actually reached the seed.
    var onRequest: ((String) -> Void)?

    init(preferredPort: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: the guest reaches this through SLIRP's host alias.
        let endpointPort = NWEndpoint.Port(rawValue: preferredPort == 0 ? NWEndpoint.Port.any.rawValue : preferredPort)!
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)
        listener = try NWListener(using: parameters)
    }

    func start(resources: [String: Resource], timeout: TimeInterval = 8) throws {
        guard !started else { return }
        self.resources = resources

        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var signalled = false
        var failure: Error?

        listener.stateUpdateHandler = { state in
            lock.lock()
            defer { lock.unlock() }
            switch state {
            case .ready:
                if !signalled {
                    signalled = true
                    ready.signal()
                }
            case .failed(let error):
                failure = error
                if !signalled {
                    signalled = true
                    ready.signal()
                }
            case .cancelled:
                if !signalled {
                    signalled = true
                    ready.signal()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw SeedServerError.timedOut
        }
        if let failure {
            listener.cancel()
            throw failure
        }
        guard let bound = listener.port?.rawValue else {
            throw SeedServerError.noPort
        }
        port = bound
        started = true
        onLog?("seed server listening on 127.0.0.1:\(port)")
    }

    func stop() {
        guard started else { return }
        started = false
        listener.cancel()
        onLog?("seed server stopped")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.onLog?("seed connection error: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = SeedServer.requestPath(request)
            self.onRequest?(path)
            let response = self.response(for: path)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for path: String) -> Data {
        let resource = resources[path]
            ?? Resource(contentType: "text/plain; charset=utf-8", body: Data("not found\n".utf8))
        let status = resources[path] == nil ? "404 Not Found" : "200 OK"
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(resource.contentType)\r\n"
        header += "Content-Length: \(resource.body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(resource.body)
        return payload
    }

    static func requestPath(_ request: String) -> String {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return "/"
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let target = String(parts[1])
        return target.split(separator: "?").first.map(String.init) ?? target
    }
}

enum SeedServerError: Error, CustomStringConvertible {
    case timedOut
    case noPort

    var description: String {
        switch self {
        case .timedOut: return "种子服务器启动超时"
        case .noPort: return "种子服务器没有绑定端口"
        }
    }
}
