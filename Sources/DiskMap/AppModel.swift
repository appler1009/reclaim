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
    @Published var zoomRoot: FileItem?
    @Published var breakdown = Breakdown()
    /// Items the user has picked for the Trash, in the order they picked them.
    @Published var staged: [FileItem] = []
    @Published var hoverItem: FileItem?
    @Published var selectedItem: FileItem?
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
                self.zoomRoot = root
                self.refreshBreakdown()
                self.phase = .ready
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

    func rescan() {
        if let scannedURL { scan(scannedURL) }
    }

    private func readVolumeInfo(for url: URL) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            volumeCapacity = UInt64(values.volumeTotalCapacity ?? 0)
            volumeFree = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

    // MARK: - Selecting things to remove

    func isStaged(_ node: FileItem) -> Bool {
        staged.contains { $0 === node }
    }

    /// Selecting a folder implies its contents, so drop anything already covered.
    func toggleStaged(_ node: FileItem) {
        if let index = staged.firstIndex(where: { $0 === node }) {
            staged.remove(at: index)
            return
        }
        guard !staged.contains(where: { node.isDescendant(of: $0) }) else { return }
        staged.removeAll { $0.isDescendant(of: node) }
        staged.append(node)
    }

    func clearStaging() { staged.removeAll() }

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
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path),
                                                  resultingItemURL: &resulting)
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
        lastReclaimed += report.bytes
        volumeFree += report.bytes
        selectedItem = nil
        // A removed node may be the folder currently in view.
        if let zoomRoot, zoomRoot.parent == nil, zoomRoot !== scanRoot { self.zoomRoot = scanRoot }
        refreshBreakdown()
        return report
    }

    // MARK: - Navigation

    func zoom(into item: FileItem) {
        guard item.isDirectory, !item.children.isEmpty else { return }
        zoomRoot = item
        refreshBreakdown()
    }

    func zoomOut() {
        if let parent = zoomRoot?.parent {
            zoomRoot = parent
            refreshBreakdown()
        }
    }

    func show(_ node: FileItem) {
        zoomRoot = node.isDirectory ? node : (node.parent ?? zoomRoot)
        selectedItem = node
        refreshBreakdown()
    }

    func refreshBreakdown() {
        guard let zoomRoot else { breakdown = Breakdown(); return }
        breakdown = Breakdown.of(zoomRoot, measure: measure)
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
