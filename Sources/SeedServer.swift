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
/// `PUT /upload/…` carries a file the guest hands over — the kernel and the
/// initrd the app boots next time. That body is binary, so nothing here decodes
/// a request into a string before the bytes have been separated from the
/// headers.
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
    var onExchange: ((Data) -> Data?)?
    var onPost: ((String, Data) -> Bool)?
    /// Called with the body of every upload: a file the guest is handing over.
    var onUpload: ((String, Data) -> Bool)?
    /// Asked for a resource the guest requests that is not one of the fixed
    /// ones: the command agent's queue answers differently every time.
    var onDynamicResource: ((String) -> Resource?)?

    /// A request's body is held in memory while it arrives, and the kernel is
    /// the largest thing anyone sends. Uploads get room for one; everything
    /// else is a report and stays small.
    private static let uploadLimit = 96 * 1024 * 1024
    private static let reportLimit = 4 * 1024 * 1024

    var sharedDirectory: SharedDirectory?

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
            let upload = SeedServer.isUpload(request)
            let limit = upload ? SeedServer.uploadLimit : SeedServer.reportLimit
            let tooBig = request.count > limit
            if isComplete || tooBig || SeedServer.isComplete(request) {
                self.respond(on: connection, request: request)
            } else {
                self.receive(connection, buffer: request)
            }
        }
    }

    private func respond(on connection: NWConnection, request: Data) {
        // Headers are ASCII, the body is not: the split happens on bytes, and
        // only the header block is ever decoded.
        guard let separator = SeedServer.headerEnd(of: request),
              let headerText = String(data: request[request.startIndex..<separator.lowerBound], encoding: .utf8) else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("bad request\n".utf8))
            return
        }
        let headerLines = headerText.components(separatedBy: "\r\n").dropFirst()
        let lengths = headerLines.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        let actualLength = request.distance(from: separator.upperBound, to: request.endIndex)
        guard !headerLines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }),
              lengths.count <= 1,
              (lengths.isEmpty ? actualLength == 0 : Int(lengths[0]) == actualLength),
              Self.isComplete(request) else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("truncated request\n".utf8))
            return
        }
        let path = SeedServer.requestPath(headerText)
        let requestLine = headerText.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        onRequest?(String(requestLine))

        let body = Data(request[separator.upperBound...])
        let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
        guard ["GET", "POST", "PUT"].contains(method) else {
            send(connection, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("method not allowed\n".utf8))
            return
        }
        if method == "PUT" || path.hasPrefix("/upload/") {
            guard method == "PUT" else {
                send(connection, status: "405 Method Not Allowed", contentType: "text/plain", body: Data("upload requires PUT\n".utf8))
                return
            }
            guard body.count <= Self.uploadLimit else {
                send(connection, status: "413 Payload Too Large", contentType: "text/plain", body: Data("upload too large\n".utf8))
                return
            }
            let name = path.hasPrefix("/upload/")
                ? String(path.dropFirst("/upload/".count))
                : String(path.dropFirst())
            guard Self.safeUploadName(name) else {
                send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("invalid upload name\n".utf8))
                return
            }
            guard DispatchQueue.main.sync(execute: { self.onUpload?(name, body) ?? false }) else {
                send(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data("upload was not saved\n".utf8))
                return
            }
            send(connection, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}\n".utf8))
            return
        }

        if method == "POST", path == "/shared" {
            guard body.count <= 400_000, let reply = sharedDirectory?.exchange(body) else {
                send(connection, status: "400 Bad Request", contentType: "application/json", body: Data("{}".utf8)); return
            }
            send(connection, status: "200 OK", contentType: "application/json", body: reply); return
        }
        if method == "POST", path == "/rpc" {
            guard body.count <= Self.reportLimit,
                  let reply = DispatchQueue.main.sync(execute: { self.onExchange?(body) }) else {
                send(connection, status: "400 Bad Request", contentType: "application/json", body: Data("{}".utf8))
                return
            }
            send(connection, status: "200 OK", contentType: "application/json", body: reply)
            return
        }
        if method == "POST" {
            guard body.count <= Self.reportLimit else {
                send(connection, status: "413 Payload Too Large", contentType: "text/plain", body: Data("report too large\n".utf8))
                return
            }
            guard DispatchQueue.main.sync(execute: { self.onPost?(path, body) ?? false }) else {
                send(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data("report rejected\n".utf8))
                return
            }
            send(connection, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}\n".utf8))
            return
        }

        let dynamic: Resource? = resources[path] == nil
            ? DispatchQueue.main.sync(execute: { self.onDynamicResource?(path) }) : nil
        let resource = resources[path]
            ?? dynamic
            ?? Resource(contentType: "text/plain; charset=utf-8", body: Data("not found\n".utf8))
        let known = resources[path] != nil || dynamic != nil
        let status = known ? "200 OK" : "404 Not Found"
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
        guard let separator = headerEnd(of: request),
              let headerText = String(data: request[request.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return false
        }
        var length: Int?
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            length = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        guard let length, length >= 0 else { return true }
        return request.count - request.distance(from: request.startIndex, to: separator.upperBound) >= length
    }

    /// Where the header block ends, as a range into the request's own bytes.
    static func headerEnd(of request: Data) -> Range<Data.Index>? {
        request.range(of: Data("\r\n\r\n".utf8))
    }

    /// True while the request is still one of the uploads, so the size it is
    /// allowed to reach can be decided before the body has arrived.
    static func isUpload(_ request: Data) -> Bool {
        guard let separator = headerEnd(of: request),
              let headerText = String(data: request[request.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return false
        }
        return requestPath(headerText).hasPrefix("/upload/")
    }

    static func requestPath(_ request: String) -> String {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return "/"
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("\\") else { return "/" }
        return path
    }

    private static func safeUploadName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.contains("..") && !name.contains("/") && !name.contains("\\")
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
