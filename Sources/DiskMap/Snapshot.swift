import Foundation

/// What a finished scan looked like, small enough to keep many of.
///
/// A full tree is hundreds of thousands of nodes; a snapshot keeps the parts
/// worth comparing later — every directory near the top, and anything large —
/// so "what grew since last week" can be answered without storing everything.
struct Snapshot: Codable, Identifiable {
    struct Entry: Codable {
        let path: String
        let bytes: UInt64
        let isDirectory: Bool
    }

    let id: UUID
    /// The scanned target, as a path.
    let target: String
    let takenAt: Date
    let totalBytes: UInt64
    let fileCount: Int
    let unreadableCount: Int
    let entries: [Entry]

    /// Directories are kept to this depth regardless of size, so the shape of
    /// the tree survives even where it is small.
    static let alwaysKeepDepth = 3
    /// Beyond that depth, an entry is kept if it is at least this fraction of
    /// the whole, which is what keeps a snapshot to a sensible size.
    static let significantFraction = 0.001
    static let maximumEntries = 2_000

    init(root: FileItem, target: String, measure: SizeMeasure, takenAt: Date = Date()) {
        self.id = UUID()
        self.target = target
        self.takenAt = takenAt
        self.totalBytes = root.size(measure)
        self.fileCount = root.fileCount
        self.unreadableCount = root.unreadableCount

        let threshold = UInt64(Double(totalBytes) * Self.significantFraction)
        var collected: [Entry] = []
        var stack: [(node: FileItem, depth: Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            for child in node.children {
                let bytes = child.size(measure)
                guard bytes > 0 else { continue }
                let worthKeeping = depth < Self.alwaysKeepDepth || bytes >= threshold
                guard worthKeeping else { continue }
                collected.append(Entry(path: child.path, bytes: bytes,
                                       isDirectory: child.isDirectory))
                if child.isDirectory { stack.append((child, depth + 1)) }
            }
        }
        // Largest first, then capped: what is dropped is what matters least.
        collected.sort { $0.bytes > $1.bytes }
        self.entries = Array(collected.prefix(Self.maximumEntries))
    }

    /// Size recorded for a path, if this snapshot kept it.
    func bytes(forPath path: String) -> UInt64? {
        if path == target { return totalBytes }
        return lookup[path]
    }

    private var lookup: [String: UInt64] {
        var map: [String: UInt64] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries { map[entry.path] = entry.bytes }
        return map
    }
}

/// The difference between what is on disk now and what a snapshot recorded.
struct SizeChange {
    let bytes: Int64
    let since: Date

    var isGrowth: Bool { bytes > 0 }
    var magnitude: UInt64 { UInt64(abs(bytes)) }

    /// "+2.3 GB", "−400 MB", or nil when nothing worth reporting moved.
    func label(minimum: UInt64 = 1024 * 1024) -> String? {
        guard magnitude >= minimum else { return nil }
        return (isGrowth ? "+" : "−") + ByteFormat.string(magnitude)
    }
}
