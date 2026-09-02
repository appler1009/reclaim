import Foundation

/// Keeps a scan's history on disk, one file per scanned target.
///
/// Plain JSON in Application Support: a handful of snapshots per target is a few
/// hundred kilobytes, and a format anything can read is worth more here than a
/// database — this is history a person or an agent may want to look at directly.
struct SnapshotStore {
    /// How many snapshots to keep per target before the oldest is dropped.
    static let keepPerTarget = 12

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Reclaim/History", isDirectory: true)
    }

    /// One file per target, named from the path so it is stable across runs and
    /// readable enough to find by hand.
    func fileURL(forTarget target: String) -> URL {
        var slug = target
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "-")
        if slug.hasPrefix("_") { slug.removeFirst() }
        if slug.isEmpty { slug = "root" }
        // Long paths would exceed the filename limit; keep the tail, which is
        // the distinguishing part, and a hash so two never collide.
        if slug.count > 80 {
            slug = String(slug.suffix(70)) + "-\(abs(target.hashValue))"
        }
        return directory.appendingPathComponent("\(slug).json")
    }

    func snapshots(forTarget target: String) -> [Snapshot] {
        guard let data = try? Data(contentsOf: fileURL(forTarget: target)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = (try? decoder.decode([Snapshot].self, from: data)) ?? []
        return stored.sorted { $0.takenAt > $1.takenAt }   // newest first
    }

    /// The most recent snapshot taken before `date`, which is what a fresh scan
    /// should be compared against.
    func mostRecent(forTarget target: String, before date: Date = Date()) -> Snapshot? {
        snapshots(forTarget: target).first { $0.takenAt < date }
    }

    @discardableResult
    func record(_ snapshot: Snapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            var history = snapshots(forTarget: snapshot.target)
            history.insert(snapshot, at: 0)
            history = Array(history.prefix(Self.keepPerTarget))

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(history).write(to: fileURL(forTarget: snapshot.target),
                                              options: .atomic)
            return true
        } catch {
            // History is a convenience: failing to write it must not disturb a scan.
            Log.warning("could not record snapshot", ["target": snapshot.target,
                                                      "error": error.localizedDescription])
            return false
        }
    }

    /// Every target with history, newest activity first.
    func targets() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { url -> (String, Date)? in
            guard let data = try? Data(contentsOf: url),
                  let history = try? decoder.decode([Snapshot].self, from: data),
                  let newest = history.max(by: { $0.takenAt < $1.takenAt }) else { return nil }
            return (newest.target, newest.takenAt)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}
