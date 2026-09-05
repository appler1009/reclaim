import Foundation

/// The names and shapes the Mac app and the companion agree on.
///
/// Both sides compile this file, so an endpoint that changes shape breaks the
/// build rather than the phone.
public enum CompanionAPI {
    /// Bonjour service type. The companion browses for this; the Mac advertises it.
    public static let serviceType = "_reclaim._tcp"
    /// Separate from the MCP port (8739): that one is loopback and stays that way.
    public static let defaultPort: UInt16 = 8740
    public static let version = "v1"
    public static let prefix = "/api/v1"

    /// TXT record keys, so a companion can name a Mac in its list before it has
    /// connected to any of them. Nothing that changes while the app runs goes in
    /// here — a TXT record is published once and would go stale.
    public enum TXT {
        public static let name = "name"
        public static let version = "version"
    }

    public static let tokenHeader = "Authorization"

    // MARK: - Handshake

    /// The one thing an unpaired companion may ask for. Deliberately says
    /// nothing about the disk: this answers "which Mac is this, and will it take
    /// a pairing code right now?".
    public struct ServiceInfo: Codable, Sendable, Equatable {
        public let name: String
        public let appVersion: String
        public let apiVersion: String
        public let tabCount: Int
        /// True while the user has a pairing code showing on the Mac. Everything
        /// else here needs a token whatever this says; it exists so the phone
        /// can tell "go and open Settings on your Mac" from "type the code".
        public let pairingOpen: Bool

        public init(name: String, appVersion: String, apiVersion: String = CompanionAPI.version,
                    tabCount: Int, pairingOpen: Bool) {
            self.name = name
            self.appVersion = appVersion
            self.apiVersion = apiVersion
            self.tabCount = tabCount
            self.pairingOpen = pairingOpen
        }
    }

    public struct PairRequest: Codable, Sendable, Equatable {
        /// The six digits shown on the Mac.
        public let code: String
        /// What the Mac should call this device in its list of paired ones.
        public let device: String

        public init(code: String, device: String) {
            self.code = code
            self.device = device
        }
    }

    public struct PairResponse: Codable, Sendable, Equatable {
        public let token: String
        public let name: String

        public init(token: String, name: String) {
            self.token = token
            self.name = name
        }
    }

    // MARK: - Tabs

    /// One open tab of the Mac app, as a row in the companion's list.
    public struct TabSummary: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        /// What the Mac shows in the tab bar.
        public let title: String
        /// The path the scan was rooted at.
        public let target: String
        /// idle | scanning | ready | failed
        public let phase: String
        public let isScanning: Bool
        /// Fraction of the top-level folders finished, while a scan is running.
        public let progress: Double?
        /// Where the Mac window itself is drilled to, which is not necessarily
        /// where the companion is looking.
        public let currentPath: String?
        public let totalBytes: UInt64
        public let totalHuman: String
        public let fileCount: Int
        /// physical | logical — the measure the Mac window is set to, which the
        /// companion follows so both show the same numbers.
        public let measure: String
        public let volume: VolumeSummary?
        /// Set when `phase` is failed.
        public let error: String?

        public init(id: String, title: String, target: String, phase: String, isScanning: Bool,
                    progress: Double?, currentPath: String?, totalBytes: UInt64,
                    totalHuman: String, fileCount: Int, measure: String,
                    volume: VolumeSummary?, error: String?) {
            self.id = id
            self.title = title
            self.target = target
            self.phase = phase
            self.isScanning = isScanning
            self.progress = progress
            self.currentPath = currentPath
            self.totalBytes = totalBytes
            self.totalHuman = totalHuman
            self.fileCount = fileCount
            self.measure = measure
            self.volume = volume
            self.error = error
        }
    }

    public struct VolumeSummary: Codable, Sendable, Equatable {
        public let name: String
        public let capacity: UInt64
        public let free: UInt64
        public let freeHuman: String
        public let trashBytes: UInt64
        public let trashHuman: String

        public init(name: String, capacity: UInt64, free: UInt64, trashBytes: UInt64) {
            self.name = name
            self.capacity = capacity
            self.free = free
            self.freeHuman = ByteFormat.string(free)
            self.trashBytes = trashBytes
            self.trashHuman = ByteFormat.string(trashBytes)
        }
    }

    public struct TabList: Codable, Sendable, Equatable {
        public let tabs: [TabSummary]

        public init(tabs: [TabSummary]) { self.tabs = tabs }
    }

    // MARK: - Nodes

    /// A direct child of the folder being viewed: one tile on the map, one row
    /// in the list.
    public struct NodeChild: Codable, Sendable, Equatable, Identifiable {
        public let path: String
        public let name: String
        public let bytes: UInt64
        public let human: String
        public let isDirectory: Bool
        public let fileCount: Int
        /// Share of the folder that contains it, 0...1.
        public let share: Double
        /// For a folder, what it mostly holds — the colour of its tile.
        public let family: FileFamily
        public let modified: Date?

        public var id: String { path }

        public init(path: String, name: String, bytes: UInt64, isDirectory: Bool,
                    fileCount: Int, share: Double, family: FileFamily, modified: Date?) {
            self.path = path
            self.name = name
            self.bytes = bytes
            self.human = ByteFormat.string(bytes)
            self.isDirectory = isDirectory
            self.fileCount = fileCount
            self.share = share
            self.family = family
            self.modified = modified
        }
    }

    public struct TypeTotal: Codable, Sendable, Equatable, Identifiable {
        public let family: FileFamily
        public let bytes: UInt64
        public let human: String
        public let files: Int

        public var id: String { family.rawValue }

        public init(family: FileFamily, bytes: UInt64, files: Int) {
            self.family = family
            self.bytes = bytes
            self.human = ByteFormat.string(bytes)
            self.files = files
        }
    }

    public struct Crumb: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let path: String

        public var id: String { path }

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// One folder of a tab's tree: everything the companion draws for a screen.
    public struct Node: Codable, Sendable, Equatable {
        public let tabID: String
        public let path: String
        public let name: String
        public let bytes: UInt64
        public let human: String
        public let isDirectory: Bool
        public let fileCount: Int
        public let directoryCount: Int
        public let measure: String
        /// The scan root first, this folder last.
        public let breadcrumb: [Crumb]
        /// Largest first, zero-byte children dropped — the same rule the Mac's
        /// own list follows.
        public let children: [NodeChild]
        /// Whole-subtree totals per family, for the summary under the list.
        public let types: [TypeTotal]
        /// How many children were left out because the list was capped.
        public let omittedChildren: Int

        public init(tabID: String, path: String, name: String, bytes: UInt64, isDirectory: Bool,
                    fileCount: Int, directoryCount: Int, measure: String, breadcrumb: [Crumb],
                    children: [NodeChild], types: [TypeTotal], omittedChildren: Int) {
            self.tabID = tabID
            self.path = path
            self.name = name
            self.bytes = bytes
            self.human = ByteFormat.string(bytes)
            self.isDirectory = isDirectory
            self.fileCount = fileCount
            self.directoryCount = directoryCount
            self.measure = measure
            self.breadcrumb = breadcrumb
            self.children = children
            self.types = types
            self.omittedChildren = omittedChildren
        }
    }

    public struct APIError: Codable, Sendable, Equatable, Error {
        public let error: String

        public init(_ error: String) { self.error = error }
    }

    // MARK: - Coding

    /// Dates as ISO 8601 on both sides, set in one place so they cannot disagree.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
