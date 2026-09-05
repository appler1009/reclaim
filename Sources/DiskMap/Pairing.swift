import CryptoKit
import Foundation

/// The devices allowed to ask this Mac what its tabs are showing.
///
/// A companion is admitted once, by typing a six-digit code the Mac is showing,
/// and gets back a token it keeps. Tokens are stored here as SHA-256 hashes:
/// this app is not sandboxed and its defaults are readable by anything running
/// as the user, so what is written down should not be usable if it is read.
///
/// The code itself is short-lived and one-shot. Six digits is a million
/// guesses, which is not much on its own — so the offer expires, is only open
/// while the user is looking at it, and a run of wrong guesses closes it.
@MainActor
final class PairedDevices: ObservableObject {
    static let key = "PairedCompanions"

    struct Device: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        /// Hex SHA-256 of the token that was issued. The token itself is only
        /// ever in flight, and only once.
        let tokenHash: String
        let pairedAt: Date
        var lastSeen: Date?
    }

    @Published private(set) var devices: [Device] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        devices = Self.read(from: defaults)
    }

    private static func read(from defaults: UserDefaults) -> [Device] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(devices), forKey: Self.key)
    }

    /// Admits a device and returns the token it should keep. The token is not
    /// stored, so it cannot be shown again — a device that loses it pairs anew.
    func admit(name: String) -> String {
        let token = Self.newToken()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices.append(Device(id: UUID().uuidString,
                              name: name.isEmpty ? "A device" : String(name.prefix(60)),
                              tokenHash: Self.hash(token),
                              pairedAt: Date(),
                              lastSeen: nil))
        save()
        return token
    }

    /// Whether a presented token belongs to a paired device, noting when it was
    /// last heard from so the settings list can say.
    func accepts(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let hash = Self.hash(token)
        guard let index = devices.firstIndex(where: { $0.tokenHash == hash }) else { return false }
        // Only once a minute: every request would otherwise write defaults.
        if devices[index].lastSeen.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            devices[index].lastSeen = Date()
            save()
        }
        return true
    }

    func forget(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        save()
    }

    func forgetAll() {
        devices.removeAll()
        save()
    }

    /// 32 random bytes, URL-safe: it travels in a header and in the phone's
    /// keychain, and neither wants padding or slashes.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A pairing code, while it is being offered.
///
/// Held in memory only: an offer that outlived the app would be an open door
/// nobody remembers leaving open.
struct PairingOffer: Equatable {
    static let lifetime: TimeInterval = 180
    /// How many wrong codes close the offer. Six digits and three tries is
    /// three in a million, which is the point of counting them.
    static let allowedAttempts = 3

    let code: String
    let expires: Date
    var attempts = 0

    init(code: String = PairingOffer.newCode(), now: Date = Date()) {
        self.code = code
        self.expires = now.addingTimeInterval(Self.lifetime)
    }

    func isOpen(now: Date = Date()) -> Bool {
        now < expires && attempts < Self.allowedAttempts
    }

    static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }
}
