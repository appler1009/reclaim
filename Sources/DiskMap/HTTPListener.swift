import Foundation
import Network

/// A very small HTTP/1.1 server.
///
/// Extracted from `MCPServer` when the companion API arrived and needed the
/// same thing on a different port with a different reach. Everything about
/// *what* is served lives in the responder; this only knows how to accept a
/// connection, read one request off it, and write one response back.
///
/// One request per connection, answered and closed. Keep-alive would save a
/// handshake and cost a connection table; a phone drilling through folders makes
/// a few requests a second at most, and this is a local network.
final class HTTPListener: @unchecked Sendable {
    struct Request {
        let method: String
        /// Everything after the host, query string included.
        let target: String
        /// Lowercased keys — HTTP header names are case-insensitive and a client
        /// that sends `authorization` must be understood.
        let headers: [String: String]
        let body: Data

        /// The path with any query string cut off.
        var path: String {
            guard let mark = target.firstIndex(of: "?") else { return target }
            return String(target[..<mark])
        }

        /// Percent-decoded query items. Repeated keys keep the last value, which
        /// is the shape this API's parameters have.
        var query: [String: String] {
            guard let mark = target.firstIndex(of: "?") else { return [:] }
            var items: [String: String] = [:]
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                guard let name = halves.first?.removingPercentEncoding else { continue }
                let value = halves.count > 1
                    ? (halves[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
                    : ""
                items[name] = value
            }
            return items
        }

        /// Path split on "/", empty components dropped: `/api/v1/tabs` → three.
        var segments: [String] {
            path.split(separator: "/").map(String.init)
        }
    }

    struct Response {
        var status: String
        var headers: [String: String] = [:]
        var body: Data

        static func json(_ text: String, status: String = "200 OK") -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"],
                     body: Data(text.utf8))
        }

        static func json(_ data: Data, status: String = "200 OK") -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }

        /// An error in the one shape every client of this app already parses.
        static func failure(_ status: String, _ message: String) -> Response {
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return json(#"{"error":"\#(escaped)"}"#, status: status)
        }

        var data: Data {
            var headers = self.headers
            headers["Content-Length"] = "\(body.count)"
            headers["Connection"] = "close"
            let head = "HTTP/1.1 \(status)\r\n"
                + headers.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)\r\n" }.joined()
                + "\r\n"
            return Data(head.utf8) + body
        }
    }

    /// Loopback keeps a server on this machine; `all` puts it on the network,
    /// which only the companion service does and only when the user asks.
    enum Reach {
        case loopback
        case all
    }

    private let responder: @Sendable (Request) async -> Response
    private let reach: Reach
    private let label: String
    private let queue: DispatchQueue
    private var listener: NWListener?
    private(set) var port: UInt16

    /// Bonjour, when this server is meant to be found rather than known about.
    private let advertise: NWListener.Service?

    /// Told the port once the system has granted one, which is a moment after
    /// `start` returns and is the only way to learn it when 0 was asked for.
    var onReady: (@Sendable (UInt16) -> Void)?

    init(port: UInt16, reach: Reach = .loopback, label: String,
         advertise: NWListener.Service? = nil,
         responder: @escaping @Sendable (Request) async -> Response) {
        self.port = port
        self.reach = reach
        self.label = label
        self.advertise = advertise
        self.responder = responder
        self.queue = DispatchQueue(label: "reclaim.http.\(label)", qos: .utility)
    }

    /// The listener once it is running, so a service can hang a Bonjour
    /// advertisement off the same socket rather than opening a second one.
    var networkListener: NWListener? { listener }

    func start() throws {
        let parameters = NWParameters.tcp
        if reach == .loopback { parameters.requiredInterfaceType = .loopback }
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters,
                                      on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let assigned = listener.port?.rawValue { self.port = assigned }
                Log.info("http listening", ["service": self.label, "port": "\(self.port)"])
                self.onReady?(self.port)
            case .failed(let error):
                Log.error("http listener failed",
                          ["service": self.label, "error": "\(error)"])
            default:
                break
            }
        }
        listener.service = advertise
        listener.serviceRegistrationUpdateHandler = { [label] change in
            if case .add(let endpoint) = change {
                Log.info("bonjour published", ["service": label, "endpoint": "\(endpoint)"])
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.parse(buffer) {
                // Detached from the connection's callback so a responder that
                // has to hop to the main actor — which every live-tab answer
                // does — is not doing it inside the network queue's callback.
                let responder = self.responder
                Task {
                    let response = await responder(request)
                    connection.send(content: response.data,
                                    completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    /// Returns nil until the whole request, headers and declared body, has arrived.
    static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            headers[pieces[0].lowercased().trimmingCharacters(in: .whitespaces)] =
                pieces[1].trimmingCharacters(in: .whitespaces)
        }

        let declared = Int(headers["content-length"] ?? "") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= declared else { return nil }
        return Request(method: String(parts[0]), target: String(parts[1]),
                       headers: headers, body: Data(body.prefix(declared)))
    }
}
