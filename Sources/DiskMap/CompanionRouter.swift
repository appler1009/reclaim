import Foundation
import ReclaimKit

/// Turns an HTTP request into an answer about the open tabs.
///
/// Nothing here knows about sockets, so every route, every refusal and the
/// whole pairing dance can be exercised by handing it a request.
///
/// Tabs only, deliberately — no MCP. This port is cleartext HTTP on every
/// interface, and the bearer token rides on it in the clear; anyone who can
/// watch the phone's traffic or stand between it and the Mac has that token
/// until it is revoked. Read access to a disk map is the price of the feature
/// and the user opts into it. `scan_now` — reading an arbitrary path and
/// writing it into history — is not, so MCP stays on loopback where an agent
/// is already on the machine. Putting it back here means TLS first.
@MainActor
enum CompanionRouter {
    static func respond(to request: HTTPListener.Request,
                        service: CompanionService) -> HTTPListener.Response {
        // `/mcp` is not under the API prefix and is dispatched on its own.
        let path = route(request) ?? []

        // Reachable from the network, so an unpaired caller is told as little as
        // the handshake needs and nothing else.
        switch (request.method, path) {
        case ("GET", ["info"]):
            return encode(CompanionAPI.ServiceInfo(name: service.deviceName,
                                                   appVersion: MCPEndpoint.serverVersion,
                                                   tabCount: LiveTabs.models.count,
                                                   pairingOpen: service.offer?.isOpen() ?? false))

        case ("POST", ["pair"]):
            return pair(request, service: service)

        default:
            break
        }

        guard service.paired.accepts(token: bearer(request)) else {
            return .failure("401 Unauthorized", "Pair this device with the Mac first.")
        }

        switch (request.method, path) {
        case ("GET", ["tabs"]):
            return encode(CompanionAPI.TabList(tabs: LiveTabs.summaries()))

        // /tabs/{id} is the tab's scan root; /tabs/{id}/node?path= is anywhere
        // inside it. One handler: the second is the first with a path given.
        case ("GET", let route) where route.first == "tabs"
            && (route.count == 2 || (route.count == 3 && route[2] == "node")):
            return node(tab: route[1], request: request)

        default:
            return .failure("404 Not Found", "No such endpoint: \(request.path)")
        }
    }

    /// The path under `/api/v1`, or nil when the request is not for the API at
    /// all — which `/mcp` is not.
    private static func route(_ request: HTTPListener.Request) -> [String]? {
        let segments = request.segments
        guard segments.count >= 2, segments[0] == "api", segments[1] == CompanionAPI.version else {
            return nil
        }
        return Array(segments.dropFirst(2))
    }

    private static func bearer(_ request: HTTPListener.Request) -> String {
        let value = request.headers["authorization"] ?? ""
        guard value.lowercased().hasPrefix("bearer ") else { return "" }
        return String(value.dropFirst("bearer ".count))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Routes

    private static func pair(_ request: HTTPListener.Request,
                             service: CompanionService) -> HTTPListener.Response {
        guard let ask = try? CompanionAPI.decoder()
            .decode(CompanionAPI.PairRequest.self, from: request.body) else {
            return .failure("400 Bad Request", "Expected a code and a device name.")
        }
        switch service.redeem(code: ask.code, device: ask.device) {
        case .success(let token):
            Log.info("companion paired", ["device": ask.device])
            return encode(CompanionAPI.PairResponse(token: token, name: service.deviceName))
        case .failure(let refusal):
            Log.warning("companion pairing refused", ["device": ask.device,
                                                      "reason": "\(refusal)"])
            return .failure("403 Forbidden", refusal.message)
        }
    }

    private static func node(tab id: String, request: HTTPListener.Request) -> HTTPListener.Response {
        guard let model = LiveTabs.model(id: id) else {
            return .failure("404 Not Found", "That tab is not open any more.")
        }
        let limit = request.query["limit"].flatMap(Int.init) ?? LiveTabs.childLimit
        guard let node = LiveTabs.node(of: model, path: request.query["path"],
                                       limit: min(limit, 5000)) else {
            // The two ways this fails read very differently to someone holding
            // the phone, so they are not one message.
            return model.scanRoot == nil
                ? .failure("409 Conflict", "That tab has not scanned anything yet.")
                : .failure("404 Not Found",
                           "\(request.query["path"] ?? "") is not in this tab's scan.")
        }
        return encode(node)
    }

    // MARK: - Encoding

    private static func encode<T: Encodable>(_ value: T) -> HTTPListener.Response {
        guard let data = try? CompanionAPI.encoder().encode(value) else {
            return .failure("500 Internal Server Error", "Could not encode the answer.")
        }
        return .json(data)
    }
}
