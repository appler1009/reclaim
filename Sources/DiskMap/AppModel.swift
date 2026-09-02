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
    @Published var lastReclaimed: UInt64 = 0
    @Published var scannedURL: URL?
    @Published var volumeCapacity: UInt64 = 0
    @Published var volumeFree: UInt64 = 0
    @Published var volumes: [VolumeInfo] = []
    /// Whole-disk scans are meaningless without Full Disk Access; we probe for it
    /// so the UI can say so before the user waits for a half-empty result.
    @Published var hasFullDiskAccess = false

    private var session: ScanSession?

    /// How an item is removed. Injectable so tests can exercise the bookkeeping
    /// around a deletion without putting anything in the real Trash.
    var trashItem: (URL) throws -> Void = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    /// Whether to ask before moving things to the Trash. Off once the user ticks
    /// "Don't ask again"; the tray offers a way back.
    var confirmsTrash: Bool {
        get { UserDefaults.standard.object(forKey: Self.confirmsTrashKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.confirmsTrashKey)
            notify()
        }
    }
    private static let confirmsTrashKey = "confirmsTrash"
    private var volumeObservers: [NSObjectProtocol] = []

    init() {
        refreshVolumes()
        hasFullDiskAccess = Self.probeFullDiskAccess()
        Log.info("volumes discovered", ["count": "\(volumes.count)",
                                        "fullDiskAccess": "\(hasFullDiskAccess)"])
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

    /// `Reclaim --open <path>` starts a scan as soon as the window appears.
    func scanLaunchArgumentIfPresent() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count else { return }
        scan(URL(fileURLWithPath: arguments[index + 1]))
    }

    func refreshVolumes() {
        volumes = VolumeScanner.mounted()
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
        staged = []
        breakdown = Breakdown()
        selectedItem = nil
        progress = ScanProgress(filesScanned: 0, bytesScanned: 0, currentPath: url.path)
        readVolumeInfo(for: url)
        refreshVolumes()

        Log.info("scan started", ["path": url.path])
        let startedAt = Date()

        session.onProgress = { [weak self] snapshot in
            DispatchQueue.main.async { self?.progress = snapshot }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let root = Scanner.scan(url: url, options: ScanOptions(), session: session)
            root?.warmTotals()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session === session else { return }
                guard !session.isCancelled else {
                    Log.info("scan cancelled", ["path": url.path])
                    self.phase = .idle
                    return
                }
                guard let root else {
                    Log.error("scan failed", ["path": url.path])
                    self.phase = .failed("Could not read \(url.path)")
                    return
                }
                self.scanRoot = root
                self.zoomRoot = self.restorePath(from: root)
                self.refreshBreakdown()
                self.phase = .ready
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

    func cancelScan() {
        session?.cancel()
        session = nil
        phase = scanRoot == nil ? .idle : .ready
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
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            volumeCapacity = UInt64(values.volumeTotalCapacity ?? 0)
            volumeFree = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

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
    func trashStaged() async -> DeleteReport {
        let items = staged
        Log.info("trash requested", ["items": "\(items.count)", "bytes": "\(stagedBytes)"])
        var report = DeleteReport()
        for node in items {
            let bytes = node.size(measure)
            do {
                try trashItem(URL(fileURLWithPath: node.path, isDirectory: node.isDirectory))
                report.trashed.append((node.name, bytes))
                report.bytes += bytes
                node.parent?.remove(child: node)
            } catch {
                report.failures.append((node.name, error.localizedDescription))
                Log.error("trash failed", ["path": node.path,
                                           "error": error.localizedDescription])
            }
        }
        Log.info("trash finished", ["trashed": "\(report.trashed.count)",
                                    "failed": "\(report.failures.count)",
                                    "bytes": "\(report.bytes)"])
        staged.removeAll()
        treeRevision += 1
        lastReclaimed += report.bytes
        volumeFree += report.bytes
        selectedItem = nil
        hover.set(nil)
        // A removed node may be the folder currently in view.
        if let zoomRoot, zoomRoot.parent == nil, zoomRoot !== scanRoot { self.zoomRoot = scanRoot }
        refreshBreakdown()
        return report
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
