import Foundation

/// The state of the volume a target sits on, at the moment a scan finished.
///
/// Kept with the scan because it is the only way to answer "the disk lost 14 GB
/// — where did it go?". A scanned tree can be flat while the volume fills up,
/// and that gap is itself the finding: local snapshots, purgeable caches and
/// anything the scan could not read all take real blocks that no walk of the
/// filesystem will ever attribute to a folder.
struct VolumeSpace: Codable, Equatable {
    /// Mount point of the volume — "/" or "/Volumes/500GB SSD".
    let volume: String
    let capacity: UInt64
    /// Free space as macOS reports it for important usage: it counts space the
    /// system would purge if pressed, so it reads higher than what is free now.
    /// This is the number Finder shows, and the one a person quotes.
    let available: UInt64
    /// Free space without that promise.
    let free: UInt64

    /// Blocks actually occupied, purgeable content included — the figure to
    /// compare a scanned tree against.
    var used: UInt64 { capacity > free ? capacity - free : 0 }
    /// What the system is holding but would give back under pressure. Where
    /// local Time Machine snapshots sit.
    var purgeable: UInt64 { available > free ? available - free : 0 }

    /// Whether `target` is the whole volume, which is the only case where the
    /// scanned total and the volume's own figures describe the same thing.
    func covers(target: String) -> Bool {
        let volume = self.volume.hasSuffix("/") && self.volume.count > 1
            ? String(self.volume.dropLast()) : self.volume
        let target = target.hasSuffix("/") && target.count > 1
            ? String(target.dropLast()) : target
        return volume == target
    }
}

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
    /// The volume this target sits on, as it stood when the scan finished.
    /// Optional because snapshots written before this existed decode without it.
    let volume: VolumeSpace?
    /// Which size this snapshot counted. A window showing logical sizes records
    /// the files' own bytes, which cannot be set against a volume's occupied
    /// blocks — so what was measured has to travel with the measurement.
    /// Absent in snapshots written before this was kept; those were physical
    /// unless somebody had changed the measure by hand, which is the app's
    /// default and the only thing an unattended scan ever records.
    let measure: SizeMeasure?

    /// Directories are kept to this depth regardless of size, so the shape of
    /// the tree survives even where it is small.
    static let alwaysKeepDepth = 3
    /// Beyond that depth, an entry is kept if it is at least this fraction of
    /// the whole, which is what keeps a snapshot to a sensible size.
    static let significantFraction = 0.001
    static let maximumEntries = 2_000

    /// What a scan held, before it was shaped into a snapshot.
    ///
    /// Collecting has to happen where the tree lives: `FileItem` is a class,
    /// and trashing removes nodes from it on the main actor. Sorting and
    /// capping are work on a value and belong anywhere but there, so the two
    /// halves are separate and only the first is tied to the actor.
    struct Draft {
        let target: String
        let totalBytes: UInt64
        let fileCount: Int
        let unreadableCount: Int
        /// In the order the walk found them, largest not yet first.
        let collected: [Entry]
    }

    /// Walks the tree. Call this where the tree is owned.
    static func draft(root: FileItem, target: String, measure: SizeMeasure) -> Draft {
        let totalBytes = root.size(measure)
        let threshold = UInt64(Double(totalBytes) * Self.significantFraction)
        // The root's name is an absolute path, and everything below is a
        // component appended to it — the same rule `FileItem.path` follows.
        var prefix = root.name
        if prefix.hasSuffix("/") { prefix.removeLast() }

        var collected: [Entry] = []
        var stack: [(node: FileItem, path: String, depth: Int)] = [(root, prefix, 0)]
        while let (node, path, depth) = stack.popLast() {
            for child in node.children {
                let bytes = child.size(measure)
                guard bytes > 0 else { continue }
                let worthKeeping = depth < Self.alwaysKeepDepth || bytes >= threshold
                guard worthKeeping else { continue }
                // Threaded down the walk rather than asked of the child:
                // `FileItem.path` climbs the parent chain and joins it afresh
                // every time, which is the same string rebuilt at every level
                // of a walk that already knows it.
                let childPath = path + "/" + child.name
                collected.append(Entry(path: childPath, bytes: bytes,
                                       isDirectory: child.isDirectory))
                if child.isDirectory { stack.append((child, childPath, depth + 1)) }
            }
        }
        return Draft(target: target, totalBytes: totalBytes, fileCount: root.fileCount,
                     unreadableCount: root.unreadableCount, collected: collected)
    }

    /// Shapes a draft into what gets stored. Pure work on values: run it off
    /// the interface's back.
    init(draft: Draft, measure: SizeMeasure, volume: VolumeSpace? = nil,
         takenAt: Date = Date()) {
        self.id = UUID()
        self.target = draft.target
        self.takenAt = takenAt
        self.volume = volume
        self.measure = measure
        self.totalBytes = draft.totalBytes
        self.fileCount = draft.fileCount
        self.unreadableCount = draft.unreadableCount
        // Largest first, then capped: what is dropped is what matters least.
        self.entries = Array(draft.collected.sorted { $0.bytes > $1.bytes }
            .prefix(Self.maximumEntries))
    }

    /// Both halves at once, for a caller with no interface to hold up.
    init(root: FileItem, target: String, measure: SizeMeasure,
         volume: VolumeSpace? = nil, takenAt: Date = Date()) {
        self.init(draft: Self.draft(root: root, target: target, measure: measure),
                  measure: measure, volume: volume, takenAt: takenAt)
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
