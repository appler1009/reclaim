import Foundation
import ReclaimKit

/// The open scans, and how to describe one to something that is not this app.
///
/// Every scan window registers itself here when its model is made. Two things
/// read the list: the nightly watchlist, which stands aside for a target a
/// window will refresh itself, and the companion service, which serves what the
/// tabs are showing to a phone.
///
/// Weakly held throughout — a window owns its model, not the other way round —
/// and dead entries are swept on every read rather than on close, because a tab
/// closing is not something a model is told about.
@MainActor
enum LiveTabs {
    private struct Weak { weak var model: AppModel? }
    private static var registered: [Weak] = []

    static func register(_ model: AppModel) {
        registered.removeAll { $0.model == nil }
        guard !registered.contains(where: { $0.model === model }) else { return }
        registered.append(Weak(model: model))
    }

    /// Open scans, in the order their windows were made.
    static var models: [AppModel] {
        registered.removeAll { $0.model == nil }
        return registered.compactMap(\.model)
    }

    static func model(id: String) -> AppModel? {
        models.first { $0.tabID == id }
    }

    /// Whether an open window is showing `target` and is in a state to rescan
    /// it tonight. A window holding items picked for the Trash is not, and the
    /// watchlist takes that target itself rather than let the night pass.
    static func canRescan(_ target: String) -> Bool {
        let target = TargetPath.normalise(target)
        return models.contains { model in
            guard model.canRescanUnattended, let showing = model.scannedURL?.path else {
                return false
            }
            return TargetPath.normalise(showing) == target
        }
    }

    // MARK: - Describing a tab

    /// How many children one folder will report. A directory with a hundred
    /// thousand entries is not a screen anyone reads, and the tail of it is
    /// bytes on the wire that the phone would drop on the floor.
    nonisolated static let childLimit = 200

    static func summaries() -> [CompanionAPI.TabSummary] {
        models.map(summary(of:))
    }

    static func summary(of model: AppModel) -> CompanionAPI.TabSummary {
        let root = model.scanRoot
        let phase: String
        var error: String?
        switch model.phase {
        case .idle: phase = "idle"
        case .scanning: phase = "scanning"
        case .ready: phase = "ready"
        case .failed(let message):
            phase = "failed"
            error = message
        }

        return CompanionAPI.TabSummary(
            id: model.tabID,
            title: root == nil && !model.isScanning ? "New Scan" : model.scanTargetName,
            target: model.scannedURL?.path ?? "",
            phase: phase,
            isScanning: model.isScanning,
            progress: model.isScanning ? model.scanCompletion.fraction : nil,
            currentPath: model.zoomRoot?.path,
            totalBytes: root?.size(model.measure) ?? 0,
            totalHuman: ByteFormat.string(root?.size(model.measure) ?? 0),
            fileCount: root?.fileCount ?? 0,
            measure: model.measure.rawValue,
            volume: volume(of: model),
            error: error)
    }

    private static func volume(of model: AppModel) -> CompanionAPI.VolumeSummary? {
        guard let url = model.scannedURL, model.volumeCapacity > 0 else { return nil }
        let name = model.volumes.first { $0.url.path == "/" && url.path == "/" }?.name
            ?? model.volumes.first { $0.url == url }?.name
            ?? "Volume"
        return CompanionAPI.VolumeSummary(name: name,
                                          capacity: model.volumeCapacity,
                                          free: model.volumeFree,
                                          trashBytes: model.trash.bytes)
    }

    /// One folder of a tab's tree, ready to draw.
    ///
    /// `path` nil means the scan root — not the folder the Mac window happens to
    /// be showing. The companion browses on its own, and a person scrolling on
    /// the Mac should not move the phone out from under whoever is holding it.
    static func node(of model: AppModel, path: String?,
                     limit: Int = childLimit) -> CompanionAPI.Node? {
        guard let root = model.scanRoot else { return nil }
        guard let node = path.map({ find(in: root, path: $0) }) ?? root else { return nil }

        let measure = model.measure
        let total = node.size(measure)
        let children = node.children
            .map { (child: $0, bytes: $0.size(measure)) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        let shown = children.prefix(max(0, limit))

        let totals = node.totals().bytes(measure)
        let counts = node.totals().counts
        let types = FileFamily.allCases
            .filter { totals[$0.index] > 0 }
            .map { CompanionAPI.TypeTotal(family: $0, bytes: totals[$0.index],
                                          files: Int(counts[$0.index])) }
            .sorted { $0.bytes > $1.bytes }

        return CompanionAPI.Node(
            tabID: model.tabID,
            path: node.path,
            name: node.name,
            bytes: total,
            isDirectory: node.isDirectory,
            fileCount: node.fileCount,
            directoryCount: children.filter { $0.child.isDirectory }.count,
            measure: measure.rawValue,
            breadcrumb: breadcrumb(from: node, to: root),
            children: shown.map { entry in
                CompanionAPI.NodeChild(
                    path: entry.child.path,
                    name: entry.child.name,
                    bytes: entry.bytes,
                    isDirectory: entry.child.isDirectory,
                    fileCount: entry.child.fileCount,
                    share: total > 0 ? Double(entry.bytes) / Double(total) : 0,
                    family: entry.child.dominantFamily(measure),
                    modified: entry.child.modified == .distantPast ? nil : entry.child.modified)
            },
            types: types,
            omittedChildren: children.count - shown.count)
    }

    /// The scan root first, `node` last.
    private static func breadcrumb(from node: FileItem, to root: FileItem) -> [CompanionAPI.Crumb] {
        var chain: [FileItem] = []
        var walker: FileItem? = node
        while let current = walker {
            chain.append(current)
            if current === root { break }
            walker = current.parent
        }
        return chain.reversed().map { CompanionAPI.Crumb(name: $0.name, path: $0.path) }
    }

    /// The node at an absolute path within a scanned tree, or nil if the path is
    /// outside it or names something the scan did not record.
    ///
    /// Walks by path component rather than comparing every node's `path`, which
    /// is built by walking the parent chain and would make this quadratic.
    static func find(in root: FileItem, path: String) -> FileItem? {
        let wanted = trimmed(path)
        let base = trimmed(root.path)
        if wanted == base { return root }
        guard wanted.hasPrefix(base + "/") else { return nil }

        var node = root
        for component in wanted.dropFirst(base.count + 1).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else {
                return nil
            }
            node = next
        }
        return node
    }

    /// A trailing slash is a spelling, not a different path — except for "/".
    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
