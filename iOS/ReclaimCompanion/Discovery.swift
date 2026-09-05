import Foundation
import Network
import ReclaimKit

/// A Mac running Reclaim, as found on the network.
struct DiscoveredMac: Identifiable, Equatable {
    /// The Bonjour instance name, which is the Mac's own name and does not
    /// change between sessions — so a paired Mac is recognised when it comes back.
    let id: String
    let name: String
    let endpoint: NWEndpoint

    static func == (lhs: DiscoveredMac, rhs: DiscoveredMac) -> Bool { lhs.id == rhs.id }
}

/// Watches the network for Macs offering Reclaim.
///
/// A browser, not a one-off search: a Mac joins the network, wakes from sleep,
/// or has the service switched on in Settings, and the list should say so
/// without anyone pulling to refresh.
@MainActor
final class Discovery: ObservableObject {
    /// How many times a browse that failed is quietly started again before the
    /// person holding the phone is told about it. Wi-Fi drops, the app comes
    /// back from the background and the browser is defunct — all of it is
    /// ordinary, and none of it is worth a screen of red text.
    static let restartsBeforeComplaining = 3

    @Published private(set) var macs: [DiscoveredMac] = []
    /// Set only when looking has actually stopped and will not resume on its
    /// own. A browse that is merely waiting is still looking.
    @Published private(set) var failure: String?
    /// Whether the browser is up. The difference between "no Macs yet" and
    /// "not even looking", which are the same empty list.
    @Published private(set) var isSearching = false

    private var browser: NWBrowser?
    private var restarts = 0

    func start() {
        guard browser == nil else { return }
        failure = nil
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: CompanionAPI.serviceType, domain: nil),
                                using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.adopt(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.adopt(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
        isSearching = true
    }

    private func adopt(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            failure = nil
            isSearching = true
            // A browse that got going is not owed the restarts an earlier one
            // used up.
            restarts = 0

        case .waiting(let error):
            // Waiting is not failing: the browser holds on and retries by
            // itself, and saying "cannot look for Macs" over a Wi-Fi hiccup
            // would be wrong the moment it is printed. The exception is
            // permission, which no amount of waiting resolves.
            isSearching = true
            failure = Self.isPermissionDenied(error) ? Self.explain(error) : nil

        case .failed(let error):
            guard !Self.isPermissionDenied(error),
                  restarts < Self.restartsBeforeComplaining else {
                isSearching = false
                failure = Self.explain(error)
                return
            }
            // A defunct browser cannot be revived; it can only be replaced.
            restarts += 1
            begin()

        case .cancelled:
            isSearching = false

        default:
            break
        }
    }

    /// Throws the browser away and starts another. The only cure for a browser
    /// that has failed, and what the refresh on the list does.
    func refresh() async {
        restarts = 0
        failure = nil
        begin()
        // Long enough for the network to answer, so a pull-to-refresh that
        // finds something does not snap shut before it appears.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func begin() {
        stop()
        start()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func adopt(_ results: Set<NWBrowser.Result>) {
        macs = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            // The TXT name is what the Mac calls itself; the instance name is
            // what Bonjour made of it, and is the fallback when there is no TXT.
            var shown = name
            if case .bonjour(let record) = result.metadata,
               let advertised = record[CompanionAPI.TXT.name], !advertised.isEmpty {
                shown = advertised
            }
            return DiscoveredMac(id: name, name: shown, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The one failure retrying cannot fix, and the one worth different words.
    private static func isPermissionDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied { return true }
        return false
    }

    private static func explain(_ error: NWError) -> String {
        if isPermissionDenied(error) {
            return "Reclaim is not allowed to use the local network. "
                + "Turn it on in Settings → Reclaim → Local Network."
        }
        return "Could not look for Macs: \(error.localizedDescription)"
    }
}

/// Turns a Bonjour service into an address that can be typed into a URL.
///
/// A `URLSession` cannot be handed an `NWEndpoint`, so the service is resolved
/// by opening a connection to it and asking the connection where it ended up.
/// Deliberately not `NetService`, which does this in three lines and is on its
/// way out.
enum Resolver {
    enum Failure: LocalizedError {
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let name): return "\(name) did not answer."
            }
        }
    }

    /// The base URL to talk to a discovered Mac, e.g. `http://192.168.1.4:8740`.
    static func baseURL(for mac: DiscoveredMac, timeout: TimeInterval = 5) async throws -> URL {
        let connection = NWConnection(to: mac.endpoint, using: .tcp)
        defer { connection.cancel() }

        let resolved: NWEndpoint = try await withCheckedThrowingContinuation { continuation in
            let once = OneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let remote = connection.currentPath?.remoteEndpoint else {
                        once.fail(Failure.unreachable(mac.name))
                        return
                    }
                    once.succeed(remote)
                case .failed(let error), .waiting(let error):
                    once.fail(error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.fail(Failure.unreachable(mac.name))
            }
        }

        guard case .hostPort(let host, let port) = resolved else {
            throw Failure.unreachable(mac.name)
        }
        guard let url = URL(string: "http://\(literal(host)):\(port.rawValue)") else {
            throw Failure.unreachable(mac.name)
        }
        return url
    }

    /// How a host goes into a URL: IPv6 in brackets, and a link-local scope id
    /// (`%en0`) percent-escaped, or `URL` refuses the string.
    private static func literal(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .ipv6(let address):
            let text = "\(address)".replacingOccurrences(of: "%", with: "%25")
            return "[\(text)]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    /// A continuation must be resumed exactly once, and this one is raced by a
    /// state change and a timeout.
    private final class OneShot: @unchecked Sendable {
        private let continuation: CheckedContinuation<NWEndpoint, Error>
        private let lock = NSLock()
        private var done = false

        init(_ continuation: CheckedContinuation<NWEndpoint, Error>) {
            self.continuation = continuation
        }

        func succeed(_ value: NWEndpoint) {
            guard claim() else { return }
            continuation.resume(returning: value)
        }

        func fail(_ error: Error) {
            guard claim() else { return }
            continuation.resume(throwing: error)
        }

        private func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
