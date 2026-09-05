import Foundation

/// Scans a target with no window, no model and no interface, and files the
/// result into history. What the watchlist and the MCP server both run.
enum UnattendedScan {
    /// Returns what was recorded, or nil if the path could not be scanned.
    @discardableResult
    static func run(path: String, store: SnapshotStore = SnapshotStore()) -> Snapshot? {
        let url = TargetPath.normalise(URL(fileURLWithPath: path))
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
        // Announced here, with the write, rather than by whoever asked for the
        // scan: an agent's `scan_now` leaves the same stale list behind that a
        // watchlist run does, and only a scan that actually recorded something
        // is news.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .reclaimHistoryChanged, object: nil,
                                            userInfo: ["target": url.path])
        }
        return snapshot
    }
}

/// Runs the watchlist overnight, on behalf of the app rather than a window.
///
/// The per-window schedule can only refresh what somebody left open; this one
/// answers to the list instead, so a target gains a point a night whether or
/// not it was looked at. It shares `NightlyRescan`'s clock, and no target is
/// scanned twice in one night: a window that will refresh a target itself
/// keeps it (see `LiveTabs`), and the claim settles anything left over —
/// a target whose window cannot rescan it, or one already run tonight.
///
/// Still in-app: nothing runs while Reclaim is closed, which is a deliberate
/// limit rather than an oversight.
@MainActor
final class WatchlistRescan {
    private let watchlist: Watchlist
    private let schedule: NightlyRescan
    /// Does the work. Injectable so tests never touch a disk. `@Sendable`
    /// because it is called on a background queue, not here.
    private let scan: @Sendable (String) -> Void
    /// Whether an open window will rescan this target itself. Injectable so a
    /// test can pose as a window without building one.
    private let windowWillHandle: (String) -> Bool
    /// How work is put on a background queue. Injectable so tests can run it
    /// inline and assert on what happened.
    private let dispatch: (@escaping @Sendable () -> Void) -> Void
    private var observation: NSObjectProtocol?

    /// One at a time, on purpose: three volume scans at once thrash the disk
    /// and take longer in total than running them in turn.
    private static let queue = DispatchQueue(label: "reclaim.watchlist", qos: .utility)

    /// The defaults are resolved inside rather than in the signature: a default
    /// argument is evaluated outside the actor, and both of these belong to it.
    init(watchlist: Watchlist? = nil,
         schedule: NightlyRescan? = nil,
         scan: @escaping @Sendable (String) -> Void = { UnattendedScan.run(path: $0) },
         windowWillHandle: ((String) -> Bool)? = nil,
         dispatch: ((@escaping @Sendable () -> Void) -> Void)? = nil) {
        let watchlist = watchlist ?? .shared
        let schedule = schedule ?? NightlyRescan()
        self.watchlist = watchlist
        self.schedule = schedule
        self.scan = scan
        self.windowWillHandle = windowWillHandle ?? { LiveTabs.canRescan($0) }
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
            // A window showing this target rescans it tonight anyway, and does
            // so visibly: it redraws the map as well as writing history. The
            // claim is deliberately not taken here, so that window can have it.
            guard !windowWillHandle(target) else {
                Log.info("watchlist rescan skipped", ["reason": "windowHasIt", "target": target])
                continue
            }
            // Or it may already have run it, minutes ago.
            guard NightlyRescan.claim(target, at: date) else {
                Log.info("watchlist rescan skipped", ["reason": "alreadyClaimed", "target": target])
                continue
            }
            taken.append(target)
        }
        guard !taken.isEmpty else { return [] }

        let scan = self.scan
        // Copied out of the mutable local: what crosses to the queue has to be
        // a value the queue owns.
        let due = taken
        dispatch {
            // One at a time, and each announces itself as it lands, so a window
            // showing the first target does not wait on the last.
            for target in due { scan(target) }
        }
        Log.info("watchlist rescan started", ["targets": taken.joined(separator: ", ")])
        return taken
    }
}
