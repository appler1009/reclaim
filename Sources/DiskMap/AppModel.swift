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
    @Published var wasteGroups: [WasteGroup] = []
    @Published var stagedIDs: Set<UUID> = []
    @Published var expandedCategories: Set<WasteCategory> = []
    @Published var hoverItem: FileItem?
    @Published var selectedItem: FileItem?
    @Published var measure: SizeMeasure = .physical
    @Published var focusWaste = true
    @Published var lastReclaimed: UInt64 = 0
    @Published var scannedURL: URL?
    @Published var volumeCapacity: UInt64 = 0
    @Published var volumeFree: UInt64 = 0
    /// Bumped whenever the reclaimable set changes, so the map view can skip
    /// rebuilding its (expensive) mark table on unrelated updates.
    @Published var wasteRevision = 0

    private var session: ScanSession?
    private var allWaste: [WasteItem] = []

    var totalWaste: UInt64 { allWaste.reduce(0) { $0 + $1.bytes } }
    var stagedItems: [WasteItem] { allWaste.filter { stagedIDs.contains($0.id) } }
    var stagedBytes: UInt64 { stagedItems.reduce(0) { $0 + $1.bytes } }
    var scannedBytes: UInt64 { scanRoot?.size(measure) ?? 0 }

    /// Nodes flagged as reclaimable, for the treemap overlay.
    var wasteMarks: [ObjectIdentifier: WasteCategory] {
        var marks: [ObjectIdentifier: WasteCategory] = [:]
        for item in allWaste { marks[ObjectIdentifier(item.node)] = item.category }
        return marks
    }

    var stagedMarks: Set<ObjectIdentifier> {
        Set(stagedItems.map { ObjectIdentifier($0.node) })
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

    func scan(_ url: URL) {
        session?.cancel()
        let session = ScanSession()
        self.session = session
        phase = .scanning
        scannedURL = url
        scanRoot = nil
        zoomRoot = nil
        allWaste = []
        wasteGroups = []
        stagedIDs = []
        selectedItem = nil
        progress = ScanProgress(filesScanned: 0, bytesScanned: 0, currentPath: url.path)
        readVolumeInfo(for: url)

        session.onProgress = { [weak self] snapshot in
            DispatchQueue.main.async { self?.progress = snapshot }
        }
        let measure = self.measure
        DispatchQueue.global(qos: .userInitiated).async {
            let root = Scanner.scan(url: url, options: ScanOptions(), session: session)
            let waste = root.map { WasteAnalyzer.analyze(root: $0, measure: measure) } ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session === session else { return }
                guard !session.isCancelled else { self.phase = .idle; return }
                guard let root else {
                    self.phase = .failed("Could not read \(url.path)")
                    return
                }
                self.scanRoot = root
                self.zoomRoot = root
                self.allWaste = waste
                self.wasteGroups = waste.grouped()
                self.wasteRevision += 1
                self.expandedCategories = Set(self.wasteGroups.prefix(1).map(\.category))
                self.phase = .ready
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

    // MARK: - Staging

    func isStaged(_ item: WasteItem) -> Bool { stagedIDs.contains(item.id) }

    func toggle(_ item: WasteItem) {
        if stagedIDs.contains(item.id) { stagedIDs.remove(item.id) } else { stagedIDs.insert(item.id) }
    }

    func stageState(of group: WasteGroup) -> Bool? {
        let staged = group.items.filter { stagedIDs.contains($0.id) }.count
        if staged == 0 { return false }
        if staged == group.items.count { return true }
        return nil  // mixed
    }

    func toggle(group: WasteGroup) {
        if stageState(of: group) == true {
            group.items.forEach { stagedIDs.remove($0.id) }
        } else {
            group.items.forEach { stagedIDs.insert($0.id) }
        }
    }

    func stageAllSafe() {
        for group in wasteGroups where group.category.isSafe {
            group.items.forEach { stagedIDs.insert($0.id) }
        }
    }

    func clearStaging() { stagedIDs.removeAll() }

    // MARK: - Deleting

    struct DeleteReport {
        var trashed: [WasteItem] = []
        var failures: [(WasteItem, String)] = []
        var bytes: UInt64 = 0
    }

    /// Moves every staged item to the Trash. Nothing is deleted outright.
    func reclaimStaged() async -> DeleteReport {
        let items = stagedItems
        var report = DeleteReport()
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                report.trashed.append(item)
                report.bytes += item.bytes
                item.node.parent?.remove(child: item.node)
            } catch {
                report.failures.append((item, error.localizedDescription))
            }
        }
        let trashedIDs = Set(report.trashed.map(\.id))
        allWaste.removeAll { trashedIDs.contains($0.id) }
        wasteGroups = allWaste.grouped()
        wasteRevision += 1
        stagedIDs.subtract(trashedIDs)
        lastReclaimed += report.bytes
        volumeFree += report.bytes
        selectedItem = nil
        return report
    }

    // MARK: - Navigation

    func zoom(into item: FileItem) {
        guard item.isDirectory, !item.children.isEmpty else { return }
        zoomRoot = item
    }

    func zoomOut() {
        if let parent = zoomRoot?.parent { zoomRoot = parent }
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
