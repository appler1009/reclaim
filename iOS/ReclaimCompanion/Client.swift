import Foundation
import ReclaimKit
import Security

/// Talks to one Mac.
///
/// Holds the resolved address and the token, and knows nothing about views. A
/// request that comes back 401 clears the token: the Mac has forgotten this
/// device, and the app should ask to pair again rather than keep failing.
actor CompanionClient {
    enum Failure: LocalizedError, Equatable {
        case notPaired
        case refused(String)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .notPaired: return "This Mac has forgotten this device. Pair it again."
            case .refused(let message): return message
            case .unreachable(let message): return message
            }
        }
    }

    private let baseURL: URL
    private var token: String?
    private let session: URLSession

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        // A local network answers fast or not at all; a minute of spinner is
        // never the right thing to show.
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    var isPaired: Bool { token != nil }

    // MARK: - Endpoints

    func info() async throws -> CompanionAPI.ServiceInfo {
        try await get("/info", authenticated: false)
    }

    /// Trades the code showing on the Mac for a token, and keeps it.
    func pair(code: String, device: String) async throws -> CompanionAPI.PairResponse {
        let body = try CompanionAPI.encoder()
            .encode(CompanionAPI.PairRequest(code: code, device: device))
        let response: CompanionAPI.PairResponse = try await send(
            request(path: "/pair", method: "POST", body: body, authenticated: false))
        token = response.token
        return response
    }

    func tabs() async throws -> [CompanionAPI.TabSummary] {
        let list: CompanionAPI.TabList = try await get("/tabs")
        return list.tabs
    }

    /// A folder inside a tab's scan. `path` nil is the scan's root.
    func node(tab: String, path: String?) async throws -> CompanionAPI.Node {
        var route = "/tabs/\(escaped(tab))"
        if let path {
            route += "/node?path=\(escaped(path))"
        }
        return try await get(route)
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        try await send(request(path: path, method: "GET", body: nil,
                               authenticated: authenticated))
    }

    private func request(path: String, method: String, body: Data?,
                         authenticated: Bool) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + CompanionAPI.prefix + path) else {
            throw Failure.unreachable("Could not build a request for \(path).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token else { throw Failure.notPaired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: CompanionAPI.tokenHeader)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            // The Mac has dropped this device: stop presenting a token it will
            // not take, so the app can offer pairing instead of failing on.
            if status == 401 {
                token = nil
                throw Failure.notPaired
            }
            let message = (try? CompanionAPI.decoder()
                .decode(CompanionAPI.APIError.self, from: data))?.error
            throw Failure.refused(message ?? "The Mac refused that (\(status)).")
        }

        do {
            return try CompanionAPI.decoder().decode(T.self, from: data)
        } catch {
            throw Failure.refused("The Mac sent something this app did not understand.")
        }
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

/// Where a Mac's token is kept between launches.
///
/// The keychain rather than defaults: this is the one secret the app holds, and
/// a backup of the device should not carry it to another phone —
/// `ThisDeviceOnly` says so.
enum TokenStore {
    private static let service = "com.appler.reclaim.companion.token"

    static func token(for macID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for macID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func forget(_ macID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: macID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
