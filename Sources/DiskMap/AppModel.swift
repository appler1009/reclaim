import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    /// Identifies this tab to anything outside the app — the companion, which
    /// has no window to point at. Made here rather than derived from the window
    /// or the target: a window arrives later than its model, and two tabs can be
    /// scanning the same folder.
    let tabID = UUID().uuidString

    @Published var phase: Phase = .idle
    @Published var progress = ScanProgress(filesScanned: 0, bytesScanned: 0, currentPath: "")
    @Published var scanRoot: FileItem?
    /// The navigation state below is deliberately not `@Published`.
    ///
    /// One navigation touches the folder in view, its breakdown, the direction of
    /// travel and the selection; as published properties that was four separate
    /// SwiftUI passes, and a profile of continuous drilling showed the view-graph
    /// update was the entire cost of a step (15ms of 15.6ms). They are changed
    /// together and announced once, through `notify()`.
    private(set) var zoomRoot: FileItem?
    private(set) var breakdown = Breakdown()
    /// Items the user has picked for the Trash, in the order they picked them.
    private(set) var staged: [FileItem] = []
    /// Direction of the last navigation, so the sidebar slides the same way the
    /// map zooms.
    private(set) var navigatedInwards = true
    /// Bumped whenever the tree itself changes — currently only by trashing.
    /// The map redraws when the folder in view changes identity, which a deletion
    /// does not do, so without this the deleted tile stayed on screen.
    private(set) var treeRevision = 0
    /// Hover lives in its own observable object so moving the pointer across the
    /// map repaints one readout instead of re-evaluating the whole window: a
    /// full SwiftUI pass costs ~10ms, and hover changes continuously.
    let hover = HoverState()
    private(set) var selectedItem: FileItem?
    @Published var measure: SizeMeasure = .physical
    @Published var scannedURL: URL?
    /// The window this scan is being shown in, once there is one. Weak: the
    /// window owns the hosting view that owns this model, not the other way
    /// round. Set by `WindowTabTitle`, which is already in the view for the
    /// same reason — it is the one place with the window in hand.
    weak var window: NSWindow?
    @Published var volumeCapacity: UInt64 = 0
    @Published var volumeFree: UInt64 = 0
    /// The scanned volume's own account of itself. Kept beside the two figures
    /// above because it also knows what the system holds as purgeable, which is
    /// space a scan will never find a file for.
    @Published var volumeSpace: VolumeSpace?
    /// What is sitting in this volume's Trash: spoken for, but not freed until
    /// the Trash is emptied.
    @Published var trash = TrashInspector.Contents()
    /// How much of that this session put there.
    @Published var trashedThisSession: UInt64 = 0
    @Published var volumes: [VolumeInfo] = []
    /// Whether the first enumeration has come back. `volumes` is filled in off
    /// the main thread, so "empty" and "not looked yet" are different states and
    /// the empty-state copy must only speak for the first.
    @Published private(set) var volumesLoaded = false
    /// Whole-disk scans are meaningless without Full Disk Access; we probe for it
    /// so the UI can say so before the user waits for a half-empty result.
    @Published var hasFullDiskAccess = false
    /// True while a scan is running, including once its first level is on screen.
    @Published var isScanning = false
    /// The previous scan of this target, if one was ever recorded, and how long
    /// ago it was taken. What makes the app able to say "this grew".
    @Published private(set) var comparison: Snapshot?
    /// What was scanned in earlier sessions, newest first. Read from disk, so it
    /// survives quitting the app.
    @Published private(set) var recentScans: [DiskQueries.TargetSummary] = []
    /// Top-level folders finished, of how many, and the fraction between them.
    @Published var scanCompletion: (done: Int, total: Int, fraction: Double) = (0, 0, 0)

    private var session: ScanSession?
    /// The scan root's children in the order the scanner numbered them, which is
    /// the order `ScanSession.branchTotals()` is indexed by. The displayed
    /// children are re-sorted on every tick, so position in `scanRoot.children`
    /// says nothing about which branch a total belongs to.
    ///
    /// These must be the very same `FileItem` instances that `scanRoot.children`
    /// holds — this is a second ordering of one set of objects, not a second set.
    /// Rebuilding it with `map`, or copying the items, would write the sizes onto
    /// objects the interface never shows.
    private var branches: [FileItem] = []
    /// Where scan history is kept. Set at construction so the load that starts
    /// immediately below reads from the right place.
    let snapshotStore: SnapshotStore
    /// Ticks the partial sizes into the tree while a scan runs.
    private var liveTimer: Timer?
    /// Rescans this window's target overnight, when that is switched on.
    private let nightly = NightlyRescan()

    /// How an item is removed. Injectable so tests can exercise the bookkeeping
    /// around a deletion without putting anything in the real Trash.
    var trashItem: (URL) throws -> Void = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    private var volumeObservers: [NSObjectProtocol] = []
    /// Kept apart from `volumeObservers`: this one is on the default centre,
    /// and an observer has to be removed from the centre it was added to.
    private var historyObserver: NSObjectProtocol?
    /// Counts enumerations so a slow one cannot overwrite a newer result.
    private var volumeRefresh = 0

    init(snapshotStore: SnapshotStore = SnapshotStore()) {
        self.snapshotStore = snapshotStore
        nightly.action = { [weak self] in self?.runNightlyRescan() }
        refreshVolumes()
        refreshRecentScans()
        hasFullDiskAccess = Self.probeFullDiskAccess()
        // So the watchlist can leave this window's own target to it.
        LiveTabs.register(self)
        Log.info("full disk access probed", ["fullDiskAccess": "\(hasFullDiskAccess)"])
        // An unattended scan of the watchlist writes history this window knows
        // nothing about; its start screen should still show it.
        historyObserver = NotificationCenter.default.addObserver(
            forName: .reclaimHistoryChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRecentScans() }
            }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach { center.removeObserver($0) }
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    private var stress: NavigationStress?

    /// `Reclaim --stress-navigate` drives navigation continuously once a scan
    /// finishes, for profiling the real UI path.
    func startNavigationStressIfRequested() {
        guard CommandLine.arguments.contains("--stress-navigate") else { return }
        let stress = NavigationStress(model: self)
        self.stress = stress
        stress.start()
    }

    /// Whether `--open` has already been honoured. Windows are independent
    /// scans, so a second one must not repeat the launch argument.
    private static var launchArgumentConsumed = false

    /// `Reclaim --open <path>` starts a scan as soon as the first window appears.
    @discardableResult
    func scanLaunchArgumentIfPresent(_ arguments: [String] = CommandLine.arguments) -> Bool {
        guard !Self.launchArgumentConsumed else { return false }
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else {
            return false
        }
        Self.launchArgumentConsumed = true
        scan(URL(fileURLWithPath: arguments[index + 1]))
        return true
    }

    /// Test seam: lets a test start from a clean launch.
    static func resetLaunchArgumentForTesting() {
        launchArgumentConsumed = false
    }

    /// Read off the main thread, and not only to be tidy.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is the number Finder shows —
    /// free space including what the system could purge — and it is the one
    /// expensive key in the set: measured across this machine's seven volumes it
    /// costs ~45ms, against 0.05ms for all the others together. It ran inside
    /// `init`, so it sat in front of the first frame, and again on every
    /// mount/unmount and after every scan.
    func refreshVolumes() {
        volumeRefresh &+= 1
        let generation = volumeRefresh
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = VolumeScanner.mounted()
            DispatchQueue.main.async {
                guard let self else { return }
                // A mount storm can start several of these; they take as long as
                // the slowest disk answers, so they can finish out of order.
                // Only the newest enumeration describes the present.
                guard generation == self.volumeRefresh else { return }
                self.volumes = found
                self.volumesLoaded = true
                Log.info("volumes discovered", ["count": "\(found.count)"])
            }
        }
    }

    /// Reloads the list of previously scanned targets from the history on disk.
    func refreshRecentScans() {
        let store = snapshotStore
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recent = DiskQueries(store: store).targets()
            DispatchQueue.main.async { self?.recentScans = recent }
        }
    }

    /// Measured off the main thread: the Trash can hold a lot of files.
    func refreshTrashSize() {
        guard let url = scannedURL else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let contents = TrashInspector.contents(forVolumeContaining: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.trash = contents
                Log.debug("trash measured", ["bytes": "\(contents.bytes)",
                                             "items": "\(contents.items)"])
            }
        }
    }

    func revealTrashInFinder() {
        guard let scannedURL else { return }
        TrashInspector.revealInFinder(forVolumeContaining: scannedURL)
    }

    /// Only an actual read tells the truth: `isReadableFile` answers POSIX
    /// permissions, and the system-wide TCC.db is world-readable anyway. Probe
    /// user-level locations that TCC really does gate, and stay quiet if none of
    /// them exist rather than nagging on a machine with nothing to check.
    private static func probeFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPaths = [home + "/Library/Safari",
                              home + "/Library/Mail",
                              home + "/Library/Cookies"]
        for path in protectedPaths where FileManager.default.fileExists(atPath: path) {
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        return true
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Short name for what is being scanned: a volume by its name, otherwise the
    /// folder's own name. The scan root's `name` is a full path, which is too
    /// long for a breadcrumb or a window title.
    var scanTargetName: String {
        guard let url = scannedURL else { return "Reclaim" }
        if url.path == "/" {
            return volumes.first { $0.isStartupVolume }?.name ?? "Macintosh HD"
        }
        if let volume = volumes.first(where: { $0.url == url }) { return volume.name }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var scannedBytes: UInt64 { scanRoot?.size(measure) ?? 0 }
    var viewedBytes: UInt64 { zoomRoot?.size(measure) ?? 0 }
    var stagedBytes: UInt64 { staged.reduce(0) { $0 + $1.size(measure) } }
    var stagedMarks: Set<ObjectIdentifier> { Set(staged.map { ObjectIdentifier($0) }) }

    /// Announces one batch of navigation/selection changes to SwiftUI.
    private func notify() {
        objectWillChange.send()
    }

    func setHover(_ item: FileItem?) {
        hover.set(item)
    }

    /// Hover reported by one contents row.
    ///
    /// A row only clears the hover while it is still the row holding it: SwiftUI
    /// can deliver a row's exit after the next row's entry, and clearing blindly
    /// blanked the highlight the pointer had just moved onto.
    func setHover(_ item: FileItem, isHovered: Bool) {
        if isHovered {
            hover.set(item)
        } else if hover.item === item {
            hover.set(nil)
        }
    }

    func setSelection(_ item: FileItem?) {
        guard item !== selectedItem else { return }
        selectedItem = item
        notify()
    }

    // MARK: - Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to analyse"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    func scan(volume: VolumeInfo) {
        scan(volume.url)
    }

    func scan(_ url: URL) {
        // Normalised here, at the one door every scan comes through, so the
        // path this window claims overnight and the target its snapshots are
        // filed under are the same string the watchlist holds.
        let url = TargetPath.normalise(url)
        session?.cancel()
        let session = ScanSession()
        self.session = session
        phase = .scanning
        // Scanning somewhere else entirely: any folder queued for restoring by a
        // rescan belongs to the previous target and must be dropped.
        if scannedURL != url { pathToRestore = [] }
        scannedURL = url
        scanRoot = nil
        zoomRoot = nil
        branches = []
        staged = []
        breakdown = Breakdown()
        selectedItem = nil
        progress = ScanProgress(filesScanned: 0, bytesScanned: 0, currentPath: url.path)
        readVolumeInfo(for: url)
        refreshVolumes()

        Log.info("scan started", ["path": url.path])
        let startedAt = Date()
        isScanning = true

        session.onProgress = { [weak self] snapshot in
            DispatchQueue.main.async { self?.progress = snapshot }
        }

        // Held strongly, deliberately, for as long as the scan runs: a window
        // closed near the end of a ten-minute volume walk should still file
        // what the walk found, and the model is what files it. The hops back
        // onto the actor take a weak reference, since by then the work is done
        // and there is nothing left to save.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let root = Scanner.scan(url: url, options: ScanOptions(), session: session) { partial in
                // The first level, milliseconds in: show it and start growing it.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === session else { return }
                    self.adoptPartial(partial, session: session)
                }
            }
            root?.warmTotals()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session === session else { return }
                self.stopLiveUpdates()
                guard !session.isCancelled else {
                    Log.info("scan cancelled", ["path": url.path])
                    self.isScanning = false
                    self.phase = self.scanRoot == nil ? .idle : .ready
                    return
                }
                guard let root else {
                    Log.error("scan failed", ["path": url.path])
                    self.isScanning = false
                    self.phase = .failed("Could not read \(url.path)")
                    return
                }
                self.scanRoot = root
                self.zoomRoot = self.restorePath(from: root)
                self.branches = []
                self.isScanning = false
                self.scanCompletion = (0, 0, 0)
                self.phase = .ready
                self.refreshBreakdown()
                self.treeRevision += 1
                self.refreshTrashSize()
                self.recordHistory(root: root, target: url.path)
                self.nightly.isArmed = true
                self.startNavigationStressIfRequested()
                Log.info("scan finished", [
                    "path": url.path,
                    "seconds": String(format: "%.2f", Date().timeIntervalSince(startedAt)),
                    "files": "\(root.fileCount)",
                    "bytes": "\(root.physicalSize)",
                    "unreadableDirs": "\(root.unreadableCount)",
                ])
            }
        }
    }

    /// Files this scan into the target's history, and keeps the previous one to
    /// compare against.
    private func recordHistory(root: FileItem, target: String) {
        let store = snapshotStore
        let measure = self.measure
        // Read here, on the main actor, while the scan's numbers are still the
        // current ones: a snapshot's volume figures have to describe the same
        // moment as its tree.
        let volume = VolumeSpace.read(for: URL(fileURLWithPath: target))
        comparison = store.mostRecent(forTarget: target)
        // Collected here, where the tree lives: trashing removes nodes from it
        // on this actor, so a walk elsewhere could be reading a folder's
        // children as one of them goes — rare, and a crash when it happens.
        // Only the walk is owed to this actor; what crosses is a value.
        let draft = Snapshot.draft(root: root, target: target, measure: measure)
        // Shaping and writing history must never hold up the interface.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Snapshot(draft: draft, measure: measure, volume: volume)
            store.record(snapshot)
            DispatchQueue.main.async { self?.refreshRecentScans() }
            Log.info("snapshot recorded", ["target": target,
                                           "bytes": "\(snapshot.totalBytes)",
                                           "entries": "\(snapshot.entries.count)"])
        }
    }

    /// How a path has changed since the last scan of this target.
    func change(forPath path: String, currentBytes: UInt64) -> SizeChange? {
        guard let comparison, let previous = comparison.bytes(forPath: path) else { return nil }
        return SizeChange(bytes: Int64(currentBytes) - Int64(previous), since: comparison.takenAt)
    }

    /// The change for the folder currently in view.
    var viewedChange: SizeChange? {
        guard let zoomRoot else { return nil }
        return change(forPath: zoomRoot.path, currentBytes: zoomRoot.size(measure))
    }

    /// Shows the first level of a running scan and starts growing its sizes from
    /// the scanner's per-branch counters.
    private func adoptPartial(_ partial: FileItem, session: ScanSession) {
        installPartial(partial, session: session)
        startLiveUpdates(session: session)
    }

    /// Shows the first level of a running scan and applies the totals once.
    ///
    /// Split out from `adoptPartial` so tests can drive the ticks themselves,
    /// through `applyBranchTotals(from:)`, without an 8 Hz timer left running
    /// against the model — see `adoptForTesting` for the same idea.
    func installPartial(_ partial: FileItem, session: ScanSession) {
        scanRoot = partial
        zoomRoot = partial
        // The same objects `scanRoot.children` holds, in the scanner's order.
        branches = partial.children
        phase = .ready              // the ordinary browsing UI, mid-scan
        applyBranchTotals(from: session)
    }

    private func startLiveUpdates(session: ScanSession) {
        stopLiveUpdates()
        // Eight times a second: fast enough to feel live, rare enough that the
        // relayout it triggers is nowhere near a frame budget.
        let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session === session, self.isScanning else { return }
                self.applyBranchTotals(from: session)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveUpdates() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// Copies the scanner's running totals onto the partial tree, largest first
    /// so the map keeps its usual ordering as it fills in.
    ///
    /// The totals are indexed by branch number and `root.children` is re-sorted
    /// below on every tick, so they are read through `branches`, which keeps the
    /// order the scanner numbered. Reading them by display position handed each
    /// folder another folder's size, and since the sizes then moved around on
    /// every tick the map's tiles swapped names several times a second.
    func applyBranchTotals(from session: ScanSession) {
        scanCompletion = session.completion()
        guard isScanning, let root = scanRoot, root === zoomRoot else { return }
        let totals = session.branchTotals()
        guard totals.bytes.count == branches.count else { return }

        var total: UInt64 = 0
        var files = 0
        for (index, child) in branches.enumerated() {
            if child.isDirectory {
                child.physicalSize = totals.bytes[index]
                child.logicalSize = totals.bytes[index]
                child.fileCount = totals.files[index]
            }
            total += child.physicalSize
            files += child.fileCount
        }
        root.physicalSize = total
        root.logicalSize = total
        root.fileCount = files
        root.children.sort { $0.physicalSize > $1.physicalSize }
        root.invalidateTotals()
        breakdown = Breakdown.of(root, measure: measure)
        treeRevision += 1
        notify()
    }

    func cancelScan() {
        stopLiveUpdates()
        isScanning = false
        session?.cancel()
        session = nil
        phase = scanRoot == nil ? .idle : .ready
    }

    /// Whether tonight's scheduled rescan can go ahead.
    ///
    /// A rescan rebuilds the tree from scratch, which drops the selection with
    /// it, so a window holding items picked for the Trash is left alone: losing
    /// that list overnight is worse than a night of missing history.
    var canRescanUnattended: Bool {
        scannedURL != nil && !isScanning && staged.isEmpty
    }

    /// The overnight run, once the hour has come. Returns what it decided.
    @discardableResult
    func runNightlyRescan() -> NightlyRescanOutcome {
        guard let target = scannedURL?.path else {
            Log.info("nightly rescan skipped", ["reason": "nothingScanned"])
            return .nothingScanned
        }
        // Items picked for the Trash: this window sits the night out, and the
        // target is deliberately left unclaimed so a sibling window showing the
        // same thing with nothing picked can still take the run.
        guard staged.isEmpty else {
            Log.info("nightly rescan skipped", ["reason": "itemsPickedForTrash", "target": target])
            return .itemsPickedForTrash
        }
        // Another window on the same target may have got here first.
        guard NightlyRescan.claim(target) else {
            Log.info("nightly rescan skipped", ["reason": "anotherWindowHasIt", "target": target])
            return .anotherWindowHasIt
        }
        // Claimed before this is checked, on purpose: a window already scanning
        // this target has the night's fresh numbers coming anyway, and holding
        // the claim is what stops a sibling starting the very same scan beside it.
        guard !isScanning else {
            Log.info("nightly rescan skipped", ["reason": "alreadyScanning", "target": target])
            return .alreadyScanning
        }
        Log.info("nightly rescan started", ["target": target])
        rescan()
        return .started
    }

    /// Rescans what was originally chosen — the whole volume or folder — because
    /// re-reading only the folder in view would leave every total above it stale.
    /// The folder you were looking at is restored afterwards, if it still exists.
    func rescan() {
        guard let scannedURL else { return }
        pathToRestore = breadcrumb.dropFirst().map(\.name)
        scan(scannedURL)
    }

    /// Path components below the scan root to re-open once a rescan finishes.
    private var pathToRestore: [String] = []

    private func restorePath(from root: FileItem) -> FileItem {
        var node = root
        for name in pathToRestore {
            guard let next = node.children.first(where: { $0.name == name }),
                  next.isDirectory else { break }
            node = next
        }
        pathToRestore = []
        return node
    }

    private func readVolumeInfo(for url: URL) {
        guard let space = VolumeSpace.read(for: url) else { return }
        volumeSpace = space
        volumeCapacity = space.capacity
        volumeFree = space.available
    }

    /// Occupied space this scan cannot attribute to anything it saw.
    ///
    /// Only meaningful when the scan covers the whole volume and is measuring
    /// space on disk: against a folder, or against the files' own sizes, the
    /// two totals are not describing the same thing. Small gaps are noise —
    /// the volume moves while the scan runs — so only a real one is reported.
    var unaccountedBytes: UInt64? {
        guard measure == .physical, !isScanning,
              let space = volumeSpace, let root = scanRoot,
              let target = scannedURL?.path, space.covers(target: target) else { return nil }
        let scanned = root.size(measure)
        guard space.used > scanned else { return nil }
        let gap = space.used - scanned
        return gap >= Self.unaccountedFloor ? gap : nil
    }

    /// Below this, the gap says more about timing than about the disk.
    static let unaccountedFloor: UInt64 = 1024 * 1024 * 1024

    /// Installs an already-scanned tree, so tests can drive the model without
    /// waiting on a background scan.
    func adoptForTesting(root: FileItem, url: URL) {
        scanRoot = root
        zoomRoot = root
        scannedURL = url
        phase = .ready
        refreshBreakdown()
    }

    // MARK: - Selecting things to remove

    func isStaged(_ node: FileItem) -> Bool {
        staged.contains { $0 === node }
    }

    /// Selecting a folder implies its contents, so drop anything already covered.
    func toggleStaged(_ node: FileItem) {
        defer { notify() }
        if let index = staged.firstIndex(where: { $0 === node }) {
            staged.remove(at: index)
            return
        }
        guard !staged.contains(where: { node.isDescendant(of: $0) }) else { return }
        staged.removeAll { $0.isDescendant(of: node) }
        staged.append(node)
    }

    func clearStaging() {
        staged.removeAll()
        notify()
    }

    // MARK: - Deleting

    struct DeleteReport {
        var trashed: [(name: String, bytes: UInt64)] = []
        var failures: [(name: String, reason: String)] = []
        var bytes: UInt64 = 0
    }

    /// Moves every selected item to the Trash. Nothing is deleted outright.
    ///
    /// Items are moved one at a time, with the file operation itself run off the
    /// main thread and the totals updated between each. That is what makes a
    /// multi-item removal visibly tick along — map, list and the header's trash
    /// figure all follow it — instead of the window sitting still and then
    /// jumping once at the end.
    func trashStaged() async -> DeleteReport {
        await trash(staged)
    }

    /// Moves specific items, leaving any unrelated selection alone — the map's
    /// context menu acts on one tile without disturbing what is ticked.
    @discardableResult
    func trash(_ items: [FileItem]) async -> DeleteReport {
        Log.info("trash requested", ["items": "\(items.count)",
                                     "bytes": "\(items.reduce(UInt64(0)) { $0 + $1.size(measure) })"])
        var report = DeleteReport()

        for node in items {
            let bytes = node.size(measure)
            let url = URL(fileURLWithPath: node.path, isDirectory: node.isDirectory)
            do {
                try await moveToTrash(url)
                report.trashed.append((node.name, bytes))
                report.bytes += bytes
                node.parent?.remove(child: node)

                // Everything the UI reads, updated for this one item.
                staged.removeAll { $0 === node }
                treeRevision += 1
                trashedThisSession += bytes
                // The bytes are not free yet — they moved into the Trash.
                trash.bytes += bytes
                trash.items += 1
                if let zoomRoot, zoomRoot.parent == nil, zoomRoot !== scanRoot {
                    self.zoomRoot = scanRoot   // the folder in view was the one removed
                }
                refreshBreakdown()             // announces the batch
            } catch {
                report.failures.append((node.name, error.localizedDescription))
                Log.error("trash failed", ["path": node.path,
                                           "error": error.localizedDescription])
            }
        }

        Log.info("trash finished", ["trashed": "\(report.trashed.count)",
                                    "failed": "\(report.failures.count)",
                                    "bytes": "\(report.bytes)"])
        selectedItem = nil
        hover.set(nil)
        refreshBreakdown()
        // Re-measure rather than trusting the running total: the Trash may hold
        // more than this session put there.
        refreshTrashSize()
        return report
    }

    /// Runs the (blocking) file operation off the main thread, so the interface
    /// keeps drawing while a large folder is moved.
    private func moveToTrash(_ url: URL) async throws {
        let operation = trashItem
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try operation(url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Navigation

    func zoom(into item: FileItem) {
        guard item.isDirectory, !item.children.isEmpty else { return }
        navigatedInwards = true
        zoomRoot = item
        breakdown = Breakdown.of(item, measure: measure)
        notify()
    }

    func zoomOut() {
        guard let parent = zoomRoot?.parent else { return }
        navigatedInwards = false
        zoomRoot = parent
        breakdown = Breakdown.of(parent, measure: measure)
        notify()
    }

    func show(_ node: FileItem) {
        // A folder with no children yet is one this scan has not reached (or was
        // stopped before reaching); entering it would show an empty map.
        if node.isDirectory, node.children.isEmpty, node !== zoomRoot {
            selectedItem = node
            notify()
            return
        }
        let target = node.isDirectory ? node : (node.parent ?? zoomRoot)
        navigatedInwards = !(zoomRoot?.isDescendant(of: target ?? node) ?? true)
        zoomRoot = target
        selectedItem = node
        breakdown = target.map { Breakdown.of($0, measure: measure) } ?? Breakdown()
        notify()
    }

    func refreshBreakdown() {
        breakdown = zoomRoot.map { Breakdown.of($0, measure: measure) } ?? Breakdown()
        notify()
    }

    var breadcrumb: [FileItem] {
        guard let zoomRoot, let scanRoot else { return [] }
        var chain: [FileItem] = []
        var node: FileItem? = zoomRoot
        while let current = node {
            chain.append(current)
            if current === scanRoot { break }
            node = current.parent
        }
        return chain.reversed()
    }

    func revealInFinder(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}
