import Foundation
import Network

/// Serves the MCP endpoint over HTTP on the loopback interface.
///
/// Localhost only, deliberately: this hands out a map of the user's disk, and
/// nothing outside this machine has any business asking. Agents run here too.
final class MCPServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 8739

    private let endpoint: MCPEndpoint
    private let queue = DispatchQueue(label: "reclaim.mcp", qos: .utility)
    private var listener: NWListener?
    private(set) var port: UInt16

    init(endpoint: MCPEndpoint = MCPEndpoint(), port: UInt16 = MCPServer.defaultPort) {
        self.endpoint = endpoint
        self.port = port
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
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
                Log.info("mcp server listening", ["url": self.url])
            case .failed(let error):
                Log.error("mcp server failed", ["error": "\(error)"])
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

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
                let response = self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private struct Request {
        let method: String
        let path: String
        let body: Data
    }

    /// Returns nil until the whole request, headers and declared body, has arrived.
    private static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length"
            else { continue }
            contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }

        let body = buffer[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]),
                       body: Data(body.prefix(contentLength)))
    }

    private func respond(to request: Request) -> Data {
        guard request.path.hasPrefix("/mcp") else {
            return Self.http(status: "404 Not Found", json: #"{"error":"try POST /mcp"}"#)
        }
        guard request.method == "POST" else {
            // A GET is how a client checks the endpoint is alive.
            return Self.http(status: "200 OK",
                             json: #"{"server":"Reclaim","transport":"streamable-http"}"#)
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            return Self.http(status: "400 Bad Request",
                             json: Self.encode(MCPEndpoint.error(id: nil, code: -32700,
                                                                 message: "Invalid JSON")))
        }

        // A batch is an array; a single call is an object.
        if let batch = message as? [[String: Any]] {
            let responses = batch.compactMap { endpoint.handle($0) }
            return responses.isEmpty
                ? Self.http(status: "202 Accepted", json: "")
                : Self.http(status: "200 OK", json: Self.encode(responses))
        }
        guard let single = message as? [String: Any] else {
            return Self.http(status: "400 Bad Request",
                             json: Self.encode(MCPEndpoint.error(id: nil, code: -32600,
                                                                 message: "Unexpected payload")))
        }
        guard let response = endpoint.handle(single) else {
            return Self.http(status: "202 Accepted", json: "")
        }
        return Self.http(status: "200 OK", json: Self.encode(response))
    }

    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys]) else {
            return #"{"error":"could not encode response"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func http(status: String, json: String) -> Data {
        let body = Data(json.utf8)
        let headers = """
            HTTP/1.1 \(status)\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        return Data(headers.utf8) + body
    }
}
