import Foundation

/// Scans a target with no window, no model and no interface, and files the
/// result into history. What the watchlist and the MCP server both run.
enum UnattendedScan {
    /// Returns what was recorded, or nil if the path could not be scanned.
    @discardableResult
    static func run(path: String, store: SnapshotStore = SnapshotStore()) -> Snapshot? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // A watched volume that is not mounted is the ordinary case, not a
        // failure: say so quietly and leave the history alone.
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.info("unattended scan skipped", ["reason": "missing", "target": url.path])
            return nil
        }
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: ScanSession()) else {
            Log.warning("unattended scan failed", ["target": url.path])
            return nil
        }
        let snapshot = Snapshot(root: root, target: url.path, measure: .physical,
                                volume: VolumeSpace.read(for: url))
        store.record(snapshot)
        Log.info("unattended scan recorded", ["target": url.path,
                                              "bytes": "\(snapshot.totalBytes)"])
        return snapshot
    }
}

/// Runs the watchlist overnight, on behalf of the app rather than a window.
///
/// The per-window schedule can only refresh what somebody left open; this one
/// answers to the list instead, so a target gains a point a night whether or
/// not it was looked at. It shares `NightlyRescan`'s clock and its claims, so a
/// window showing a watched target and this runner never scan the same thing
/// twice in one night — whichever gets there first takes it.
///
/// Still in-app: nothing runs while Reclaim is closed, which is a deliberate
/// limit rather than an oversight.
@MainActor
final class WatchlistRescan {
    private let watchlist: Watchlist
    private let schedule: NightlyRescan
    /// Does the work. Injectable so tests never touch a disk.
    private let scan: (String) -> Void
    /// How work is put on a background queue. Injectable so tests can run it
    /// inline and assert on what happened.
    private let dispatch: (@escaping () -> Void) -> Void
    private var observation: NSObjectProtocol?

    /// One at a time, on purpose: three volume scans at once thrash the disk
    /// and take longer in total than running them in turn.
    private static let queue = DispatchQueue(label: "reclaim.watchlist", qos: .utility)

    /// The defaults are resolved inside rather than in the signature: a default
    /// argument is evaluated outside the actor, and both of these belong to it.
    init(watchlist: Watchlist? = nil,
         schedule: NightlyRescan? = nil,
         scan: @escaping (String) -> Void = { UnattendedScan.run(path: $0) },
         dispatch: ((@escaping () -> Void) -> Void)? = nil) {
        let watchlist = watchlist ?? .shared
        let schedule = schedule ?? NightlyRescan()
        self.watchlist = watchlist
        self.schedule = schedule
        self.scan = scan
        self.dispatch = dispatch ?? { work in Self.queue.async(execute: work) }
        schedule.action = { [weak self] in self?.runDue() }
        schedule.isArmed = !watchlist.targets.isEmpty
        // The list changing arms or disarms the schedule: an empty watchlist
        // books nothing, and adding the first target books tonight.
        observation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.armFromList() }
            }
    }

    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
    }

    func armFromList() {
        schedule.isArmed = !watchlist.targets.isEmpty
    }

    /// When the next run is booked for, for anything that wants to say so.
    var scheduledFor: Date? { schedule.scheduledFor }

    /// Scans every watched target that nothing else has claimed tonight.
    /// Returns the targets it took, which is what the tests assert on.
    @discardableResult
    func runDue(at date: Date = Date()) -> [String] {
        let targets = watchlist.targets
        guard !targets.isEmpty else { return [] }
        var taken: [String] = []
        for target in targets {
            // A window already showing this target may have run it minutes ago.
            guard NightlyRescan.claim(target, at: date) else {
                Log.info("watchlist rescan skipped", ["reason": "alreadyClaimed", "target": target])
                continue
            }
            taken.append(target)
        }
        guard !taken.isEmpty else { return [] }

        let scan = self.scan
        dispatch {
            for target in taken {
                scan(target)
                // Announced per target rather than at the end, so a window
                // showing the first one does not wait on the last.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .reclaimHistoryChanged,
                                                    object: nil,
                                                    userInfo: ["target": target])
                }
            }
        }
        Log.info("watchlist rescan started", ["targets": taken.joined(separator: ", ")])
        return taken
    }
}
