import Foundation
import Network
import ReclaimKit

/// Serves the open tabs to a companion app on the same network.
///
/// This is the one part of Reclaim that leaves the machine, so it is off until
/// the user turns it on, and every request but the handshake carries a token
/// that a device only gets by typing a code shown on this Mac. The MCP server
/// stays where it is — loopback, unauthenticated — because an agent running
/// here is already inside.
///
/// The same port also answers `/mcp`, so an agent on the phone, or on any
/// machine the user has paired, can ask the same questions an agent here can.
@MainActor
final class CompanionService: ObservableObject {
    static let enabledKey = "CompanionEnabled"

    /// One per app: the port can only be held once, and Settings and the menu
    /// must be looking at the same thing.
    static let shared = CompanionService()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = CompanionAPI.defaultPort
    /// The code being offered, while one is. Published so Settings can show it
    /// counting down and stop showing it the moment it is used.
    @Published private(set) var offer: PairingOffer?
    /// Set when starting failed — usually the port being held by something else.
    @Published private(set) var failure: String?

    let paired: PairedDevices
    private let defaults: UserDefaults
    private var listener: HTTPListener?
    private var expiryTimer: Timer?

    init(defaults: UserDefaults = .standard, paired: PairedDevices? = nil) {
        self.defaults = defaults
        self.paired = paired ?? PairedDevices(defaults: defaults)
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// What this Mac calls itself, which is what the phone shows in its list.
    var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var address: String { "http://\(ProcessInfo.processInfo.hostName):\(port)" }

    // MARK: - Running

    /// Brings the server up or down and remembers which the user asked for.
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
    }

    /// Starts if the user had it on when they last quit.
    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func start() {
        guard listener == nil else { return }
        failure = nil
        let service = NWListener.Service(
            name: deviceName,
            type: CompanionAPI.serviceType,
            txtRecord: NWTXTRecord([
                CompanionAPI.TXT.name: deviceName,
                CompanionAPI.TXT.version: MCPEndpoint.serverVersion,
            ]))

        // The router is reached on the main actor because everything it answers
        // with — the tabs, the paired devices — lives there.
        let listener = HTTPListener(port: CompanionAPI.defaultPort, reach: .all,
                                    label: "companion", advertise: service) { [weak self] request in
            // Bound to a `let` before the hop: a weak `self` read inside the
            // isolated closure is a captured var, which Swift 6 refuses.
            guard let service = self else {
                return .failure("503 Service Unavailable", "Reclaim is shutting down.")
            }
            return await MainActor.run { CompanionRouter.respond(to: request, service: service) }
        }
        listener.onReady = { [weak self] port in
            Task { @MainActor in self?.port = port }
        }
        do {
            try listener.start()
            self.listener = listener
            isRunning = true
            Log.info("companion service on", ["port": "\(port)", "name": deviceName])
        } catch {
            failure = "\(error)"
            Log.error("companion service failed to start", ["error": "\(error)"])
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        isRunning = false
        cancelPairing()
        Log.info("companion service off", [:])
    }

    // MARK: - Pairing

    /// Shows a code for the next few minutes. Replacing an open offer rather
    /// than refusing: a user pressing the button again wants a fresh code.
    @discardableResult
    func offerPairing(now: Date = Date()) -> PairingOffer {
        let offer = PairingOffer(now: now)
        self.offer = offer
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: PairingOffer.lifetime,
                                           repeats: false) { [weak self] _ in
            Task { @MainActor in self?.cancelPairing() }
        }
        return offer
    }

    func cancelPairing() {
        offer = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    /// Trades a code for a token, or says why not.
    ///
    /// A wrong guess is counted, and the third closes the offer — six digits is
    /// only worth anything if nobody may keep trying.
    func redeem(code: String, device: String, now: Date = Date()) -> Result<String, PairingRefusal> {
        guard var offer, offer.isOpen(now: now) else {
            cancelPairing()
            return .failure(.noOffer)
        }
        guard code == offer.code else {
            offer.attempts += 1
            self.offer = offer.isOpen(now: now) ? offer : nil
            return .failure(.wrongCode)
        }
        // One code, one device: a code that stayed live after it was used would
        // let anyone who saw the screen pair later.
        cancelPairing()
        return .success(paired.admit(name: device))
    }

    enum PairingRefusal: Error {
        case noOffer
        case wrongCode

        var message: String {
            switch self {
            case .noOffer:
                return "This Mac is not offering a pairing code. "
                    + "Open Reclaim → Settings → Companion and press Pair a Device."
            case .wrongCode:
                return "That code is not the one showing on the Mac."
            }
        }
    }
}
