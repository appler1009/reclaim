import Foundation

/// Answers questions about recorded scans.
///
/// Everything an agent can ask goes through here, and nothing in it knows about
/// HTTP or JSON-RPC — that keeps the interesting logic testable without sockets.
/// The two things a space report has to read live rather than from history,
/// injectable so the report can be tested without a Time Machine or a Trash.
struct SpaceProbe {
    var localSnapshots: (String) -> [LocalSnapshots.Entry] = { volume in
        LocalSnapshots.list(volume: volume)
    }
    var trashBytes: (String) -> UInt64? = { volume in
        TrashInspector.contents(forVolumeContaining: URL(fileURLWithPath: volume)).bytes
    }
}

struct DiskQueries {
    let store: SnapshotStore

    init(store: SnapshotStore = SnapshotStore()) {
        self.store = store
    }

    // MARK: - Results

    struct TargetSummary: Codable {
        let target: String
        let lastScan: Date
        let totalBytes: UInt64
        let totalHuman: String
        let fileCount: Int
        let unreadableCount: Int
        let scanCount: Int
    }

    struct UsageEntry: Codable {
        let path: String
        let bytes: UInt64
        let human: String
        let isDirectory: Bool
        let shareOfParent: Double
    }

    struct Usage: Codable {
        let target: String
        let path: String
        let bytes: UInt64
        let human: String
        let asOf: Date
        let children: [UsageEntry]
    }

    struct Change: Codable {
        let path: String
        let bytes: Int64
        let human: String
        let wasBytes: UInt64
        let nowBytes: UInt64
    }

    struct Growth: Codable {
        let target: String
        let from: Date
        let to: Date
        let totalChange: Int64
        let totalChangeHuman: String
        let changes: [Change]
    }

    /// The volume's own figures at one recorded scan, beside what that scan
    /// could actually account for.
    struct SpacePoint: Codable {
        let takenAt: Date
        let capacity: UInt64
        /// Free space as Finder reports it — the number a person quotes.
        let available: UInt64
        let availableHuman: String
        /// Free space not counting what the system would purge.
        let free: UInt64
        /// Blocks occupied, purgeable content included.
        let used: UInt64
        let usedHuman: String
        let purgeable: UInt64
        let purgeableHuman: String
        /// What the scan added up to.
        let scannedBytes: UInt64
        let scannedHuman: String
        /// Occupied space the scan could not attribute to any folder. Nil
        /// whenever the subtraction would be meaningless: a scan of a folder
        /// rather than the whole volume, or one that counted the files' own
        /// sizes rather than the blocks they occupy.
        let unaccounted: Int64?
        let unaccountedHuman: String?
    }

    /// How the volume moved between the latest scan and an earlier one.
    struct SpaceChange: Codable {
        let from: Date
        let to: Date
        /// Positive means free space went up.
        let available: Int64
        let availableHuman: String
        let used: Int64
        let usedHuman: String
        let scanned: Int64
        let scannedHuman: String
        let unaccounted: Int64?
        let unaccountedHuman: String?
    }

    struct SpaceReport: Codable {
        let target: String
        let volume: String
        /// Whether the scan covered the whole volume. Without this, only the
        /// volume figures mean anything; the comparison against the scan does not.
        let coversWholeVolume: Bool
        let latest: SpacePoint
        /// Oldest first, for plotting the trend.
        let points: [SpacePoint]
        /// Nil when only one scan carries volume figures.
        let change: SpaceChange?
        /// Read live, not from history: what Time Machine is pinning right now.
        let localSnapshots: [LocalSnapshots.Entry]
        /// Read live: bytes in this volume's Trash, spoken for but not freed.
        let trashBytes: UInt64?
        let trashHuman: String?
        /// The finding in a sentence, so an agent does not have to derive it.
        let summary: String
    }

    struct HistoryPoint: Codable {
        let takenAt: Date
        let totalBytes: UInt64
        let human: String
        let fileCount: Int
    }

    // MARK: - Queries

    /// Every target with recorded history, most recently scanned first.
    func targets() -> [TargetSummary] {
        store.targets().compactMap { target in
            let history = store.snapshots(forTarget: target)
            guard let newest = history.first else { return nil }
            return TargetSummary(target: target,
                                 lastScan: newest.takenAt,
                                 totalBytes: newest.totalBytes,
                                 totalHuman: ByteFormat.string(newest.totalBytes),
                                 fileCount: newest.fileCount,
                                 unreadableCount: newest.unreadableCount,
                                 scanCount: history.count)
        }
    }

    /// What a path holds, and what is directly inside it, from the latest scan.
    func usage(target: String, path: String? = nil, limit: Int = 25) -> Usage? {
        guard let snapshot = store.snapshots(forTarget: target).first else { return nil }
        let path = path ?? target
        guard let bytes = snapshot.bytes(forPath: path) else { return nil }

        // Direct children only: an entry whose parent directory is `path`.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let children = snapshot.entries
            .filter { entry in
                guard entry.path.hasPrefix(prefix) else { return false }
                let rest = entry.path.dropFirst(prefix.count)
                return !rest.contains("/")
            }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { entry in
                UsageEntry(path: entry.path,
                           bytes: entry.bytes,
                           human: ByteFormat.string(entry.bytes),
                           isDirectory: entry.isDirectory,
                           shareOfParent: bytes > 0 ? Double(entry.bytes) / Double(bytes) : 0)
            }

        return Usage(target: target, path: path, bytes: bytes,
                     human: ByteFormat.string(bytes), asOf: snapshot.takenAt,
                     children: Array(children))
    }

    /// The biggest things anywhere in the latest scan of a target.
    func largest(target: String, limit: Int = 20, directoriesOnly: Bool = false) -> [UsageEntry] {
        guard let snapshot = store.snapshots(forTarget: target).first else { return [] }
        return snapshot.entries
            .filter { !directoriesOnly || $0.isDirectory }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { entry in
                UsageEntry(path: entry.path,
                           bytes: entry.bytes,
                           human: ByteFormat.string(entry.bytes),
                           isDirectory: entry.isDirectory,
                           shareOfParent: snapshot.totalBytes > 0
                               ? Double(entry.bytes) / Double(snapshot.totalBytes) : 0)
            }
    }

    /// What changed between the latest scan and the last one taken before `since`.
    func growth(target: String, since: Date? = nil, limit: Int = 20) -> Growth? {
        let history = store.snapshots(forTarget: target)
        guard let newest = history.first else { return nil }
        let cutoff = since ?? newest.takenAt
        // The most recent scan at or before the cutoff, excluding the newest one.
        guard let baseline = history.dropFirst().first(where: { $0.takenAt <= cutoff })
                ?? history.dropFirst().first else { return nil }

        var previous: [String: UInt64] = [:]
        for entry in baseline.entries { previous[entry.path] = entry.bytes }
        var current: [String: UInt64] = [:]
        for entry in newest.entries { current[entry.path] = entry.bytes }

        var changes: [Change] = []
        for path in Set(previous.keys).union(current.keys) {
            let was = previous[path] ?? 0
            let now = current[path] ?? 0
            let delta = Int64(now) - Int64(was)
            guard delta != 0 else { continue }
            changes.append(Change(path: path,
                                  bytes: delta,
                                  human: (delta > 0 ? "+" : "−") + ByteFormat.string(UInt64(abs(delta))),
                                  wasBytes: was,
                                  nowBytes: now))
        }
        changes.sort { abs($0.bytes) > abs($1.bytes) }

        let total = Int64(newest.totalBytes) - Int64(baseline.totalBytes)
        return Growth(target: target,
                      from: baseline.takenAt,
                      to: newest.takenAt,
                      totalChange: total,
                      totalChangeHuman: (total > 0 ? "+" : "−") + ByteFormat.string(UInt64(abs(total))),
                      changes: Array(changes.prefix(limit)))
    }

    /// What the volume itself did across a target's recorded scans, and how
    /// much of it the scans could account for.
    ///
    /// The question this exists for is "free space dropped and nothing in the
    /// tree grew — where did it go?". Answering it needs the volume's own
    /// numbers over time, which a walk of the filesystem cannot supply, and a
    /// live look at the two places space hides: local snapshots and the Trash.
    /// `since` picks the baseline the way `growth` does: the most recent scan
    /// at or before it, falling back to the oldest on record. Without it the
    /// change spans the whole retained window.
    func space(target: String, since: Date? = nil,
               probe: SpaceProbe = SpaceProbe()) -> SpaceReport? {
        let history = store.snapshots(forTarget: target)
            .filter { $0.volume != nil }
            .sorted { $0.takenAt < $1.takenAt }   // oldest first
        guard let newest = history.last, let volume = newest.volume else { return nil }

        let coversWholeVolume = volume.covers(target: target)
        let points = history.compactMap { Self.point(for: $0, coversWholeVolume: coversWholeVolume) }
        guard let latest = points.last else { return nil }

        var change: SpaceChange?
        let earlier = points.dropLast()
        let baseline = since.flatMap { cutoff in earlier.last { $0.takenAt <= cutoff } }
            ?? earlier.first
        if let first = baseline {
            let available = Int64(latest.available) - Int64(first.available)
            let used = Int64(latest.used) - Int64(first.used)
            let scanned = Int64(latest.scannedBytes) - Int64(first.scannedBytes)
            // Only where both ends could be attributed: differencing a point
            // that has no gap against one that does invents a movement.
            let unaccounted = (latest.unaccounted != nil && first.unaccounted != nil)
                ? latest.unaccounted! - first.unaccounted! : nil
            change = SpaceChange(from: first.takenAt, to: latest.takenAt,
                                 available: available, availableHuman: Self.signed(available),
                                 used: used, usedHuman: Self.signed(used),
                                 scanned: scanned, scannedHuman: Self.signed(scanned),
                                 unaccounted: unaccounted,
                                 unaccountedHuman: unaccounted.map(Self.signed))
        }

        let snapshots = probe.localSnapshots(volume.volume)
        let trash = probe.trashBytes(volume.volume)
        return SpaceReport(target: target,
                           volume: volume.volume,
                           coversWholeVolume: coversWholeVolume,
                           latest: latest,
                           points: points,
                           change: change,
                           localSnapshots: snapshots,
                           trashBytes: trash,
                           trashHuman: trash.map(ByteFormat.string),
                           summary: Self.summarise(latest: latest, change: change,
                                                   coversWholeVolume: coversWholeVolume,
                                                   snapshots: snapshots, trash: trash))
    }

    private static func point(for snapshot: Snapshot, coversWholeVolume: Bool) -> SpacePoint? {
        guard let volume = snapshot.volume else { return nil }
        // The same rule the header strip applies: blocks can only be set
        // against blocks. A snapshot from before the measure was recorded is
        // taken at the app's default, which is what it will have been.
        let countedBlocks = (snapshot.measure ?? .physical) == .physical
        let unaccounted = coversWholeVolume && countedBlocks
            ? Int64(volume.used) - Int64(snapshot.totalBytes) : nil
        return SpacePoint(takenAt: snapshot.takenAt,
                          capacity: volume.capacity,
                          available: volume.available,
                          availableHuman: ByteFormat.string(volume.available),
                          free: volume.free,
                          used: volume.used,
                          usedHuman: ByteFormat.string(volume.used),
                          purgeable: volume.purgeable,
                          purgeableHuman: ByteFormat.string(volume.purgeable),
                          scannedBytes: snapshot.totalBytes,
                          scannedHuman: ByteFormat.string(snapshot.totalBytes),
                          unaccounted: unaccounted,
                          unaccountedHuman: unaccounted.map(Self.signed))
    }

    /// "+2.3 GB" / "−400 MB", sign always shown: these are deltas, and a bare
    /// number reads as a total.
    static func signed(_ bytes: Int64) -> String {
        (bytes < 0 ? "−" : "+") + ByteFormat.string(UInt64(abs(bytes)))
    }

    /// States the finding plainly, and only claims what the figures support.
    private static func summarise(latest: SpacePoint, change: SpaceChange?,
                                  coversWholeVolume: Bool,
                                  snapshots: [LocalSnapshots.Entry],
                                  trash: UInt64?) -> String {
        var parts: [String] = []
        if let change, change.available != 0 {
            parts.append("Free space \(change.available < 0 ? "fell" : "rose") by "
                         + "\(ByteFormat.string(UInt64(abs(change.available)))) "
                         + "to \(latest.availableHuman).")
        } else {
            parts.append("Free space is \(latest.availableHuman) of \(ByteFormat.string(latest.capacity)).")
        }

        if latest.unaccounted != nil {
            if let change, let unaccounted = change.unaccounted {
                parts.append("The scanned tree moved \(change.scannedHuman) while occupied space "
                             + "moved \(change.usedHuman), leaving \(signed(unaccounted)) "
                             + "that no folder accounts for.")
            }
            if let unaccounted = latest.unaccounted, unaccounted > 0 {
                parts.append("\(ByteFormat.string(UInt64(unaccounted))) of the disk is occupied by "
                             + "something the scan cannot see.")
            }
        } else if coversWholeVolume {
            parts.append("The last scan counted the files' own sizes rather than the space "
                         + "they occupy, so its total cannot be set against the volume's. "
                         + "Scan it again showing size on disk.")
        } else {
            parts.append("The scan covered a folder, not the whole volume, so its total "
                         + "cannot be subtracted from the volume's.")
        }

        if latest.purgeable > 0 {
            parts.append("\(latest.purgeableHuman) of that is purgeable — space the system "
                         + "would give back under pressure.")
        }
        if !snapshots.isEmpty {
            let when = snapshots.compactMap(\.takenAt).min()
            parts.append("\(snapshots.count) local Time Machine snapshot"
                         + "\(snapshots.count == 1 ? "" : "s") "
                         + (when.map { "going back to \(ISO8601DateFormatter().string(from: $0)) " } ?? "")
                         + "are pinning blocks that no file references.")
        }
        if let trash, trash > 0 {
            parts.append("\(ByteFormat.string(trash)) is in the Trash, not yet given back.")
        }
        return parts.joined(separator: " ")
    }

    /// Every recorded scan of a target, oldest first, for plotting a trend.
    func history(target: String) -> [HistoryPoint] {
        store.snapshots(forTarget: target)
            .sorted { $0.takenAt < $1.takenAt }
            .map { HistoryPoint(takenAt: $0.takenAt,
                                totalBytes: $0.totalBytes,
                                human: ByteFormat.string($0.totalBytes),
                                fileCount: $0.fileCount) }
    }
}
