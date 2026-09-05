import Foundation

/// Serves the MCP endpoint over HTTP on the loopback interface.
///
/// Localhost only, deliberately: this hands out a map of the user's disk, and
/// nothing outside this machine has any business asking. Agents run here too.
/// The companion service reaches the network instead, and pays for it with a
/// pairing step — see `CompanionService`.
final class MCPServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 8739

    private let endpoint: MCPEndpoint
    private var listener: HTTPListener?
    /// What was asked for, which is not what was granted: port 0 means "any
    /// free one", and the answer only arrives when the listener is ready.
    private let requestedPort: UInt16

    /// Read from the listener rather than copied at start, so a caller that
    /// asked for any free port learns which one it got.
    var port: UInt16 { listener?.port ?? requestedPort }

    init(endpoint: MCPEndpoint = MCPEndpoint(), port: UInt16 = MCPServer.defaultPort) {
        self.endpoint = endpoint
        self.requestedPort = port
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    func start() throws {
        let endpoint = self.endpoint
        let listener = HTTPListener(port: requestedPort, reach: .loopback, label: "mcp") { request in
            MCPRouter.respond(to: request, endpoint: endpoint)
        }
        try listener.start()
        self.listener = listener
    }

    func stop() {
        listener?.stop()
        listener = nil
    }
}

/// Turns an HTTP request into a JSON-RPC exchange with `MCPEndpoint`.
///
/// Free of sockets on purpose, so the whole surface — the wrong method, a batch,
/// malformed JSON — is testable by handing it a request.
enum MCPRouter {
    static func respond(to request: HTTPListener.Request,
                        endpoint: MCPEndpoint) -> HTTPListener.Response {
        guard request.path.hasPrefix("/mcp") else {
            return .failure("404 Not Found", "try POST /mcp")
        }
        guard request.method == "POST" else {
            // A GET is how a client checks the endpoint is alive.
            return .json(#"{"server":"Reclaim","transport":"streamable-http"}"#)
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(encode(MCPEndpoint.error(id: nil, code: -32700,
                                                  message: "Invalid JSON")),
                         status: "400 Bad Request")
        }

        // A batch is an array; a single call is an object.
        if let batch = message as? [[String: Any]] {
            let responses = batch.compactMap { endpoint.handle($0) }
            return responses.isEmpty
                ? .json("", status: "202 Accepted")
                : .json(encode(responses))
        }
        guard let single = message as? [String: Any] else {
            return .json(encode(MCPEndpoint.error(id: nil, code: -32600,
                                                  message: "Unexpected payload")),
                         status: "400 Bad Request")
        }
        guard let response = endpoint.handle(single) else {
            return .json("", status: "202 Accepted")
        }
        return .json(encode(response))
    }

    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys]) else {
            return #"{"error":"could not encode response"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
