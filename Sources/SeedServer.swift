import Foundation
import Network

/// Serves cloud-init's NoCloud seed to the guest over the emulated network.
///
/// QEMU's user-mode networking makes the guest's `10.0.2.2` an alias for the
/// host's loopback, so a listener bound to `127.0.0.1` is reachable from inside
/// the guest with no port forwarding and without tripping iOS's local network
/// permission prompt, which only covers non-loopback listeners.
///
/// It serves GETs (cloud-init's seed and the guest-side helpers) and accepts
/// POSTs, which is how the guest tells the host things: a structured body over
/// HTTP instead of scraping the serial console, where the tty's own echo, its
/// CR LF line endings and its escape sequences all have to be guessed at.
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
    /// Called with each request line, so the host log shows whether the guest
    /// actually reached the server.
    var onRequest: ((String) -> Void)?
    /// Called with the body of every POST: the guest reporting something.
    var onPost: ((String, Data) -> Void)?

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
        receive(connection, buffer: Data())
    }

    /// Reads until the request is whole. A POST carries a JSON body, and a body
    /// that arrives in two packets is normal, not an error.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.onLog?("connection error: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            var request = buffer
            if let data { request.append(data) }
            let tooBig = request.count > 4 * 1024 * 1024
            if isComplete || tooBig || SeedServer.isComplete(request) {
                self.respond(on: connection, request: request)
            } else {
                self.receive(connection, buffer: request)
            }
        }
    }

    private func respond(on connection: NWConnection, request: Data) {
        let text = String(decoding: request, as: UTF8.self)
        let path = SeedServer.requestPath(text)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        onRequest?(String(requestLine))

        if requestLine.hasPrefix("POST ") {
            let separator = text.range(of: "\r\n\r\n")
            let body = separator.map { Data(text[$0.upperBound...].utf8) } ?? Data()
            onPost?(path, body)
            send(connection, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}\n".utf8))
            return
        }

        let resource = resources[path]
            ?? Resource(contentType: "text/plain; charset=utf-8", body: Data("not found\n".utf8))
        let status = resources[path] == nil ? "404 Not Found" : "200 OK"
        send(connection, status: status, contentType: resource.contentType, body: resource.body)
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// True once the headers are in and, if the request declares a body, all of
    /// it has arrived.
    static func isComplete(_ request: Data) -> Bool {
        guard let text = String(data: request, encoding: .utf8),
              let separator = text.range(of: "\r\n\r\n") else { return false }
        var length = 0
        for line in text[..<separator.lowerBound].split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return text[separator.upperBound...].utf8.count >= length
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
