import Foundation

/// Answers questions about recorded scans.
///
/// Everything an agent can ask goes through here, and nothing in it knows about
/// HTTP or JSON-RPC — that keeps the interesting logic testable without sockets.
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
