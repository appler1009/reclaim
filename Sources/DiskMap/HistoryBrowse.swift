import Foundation
import ReclaimKit

/// Turns recorded snapshots of watched targets into what the companion draws.
///
/// A live tab has the full tree. A watched folder has the latest snapshot,
/// which keeps the shape of the top and anything large, and drops the rest.
/// The phone can still walk what was kept; it cannot pretend the walk is live.
@MainActor
enum HistoryBrowse {
    /// Watchlist rows, skipping targets an open tab is already showing.
    static func summaries(from watchlist: Watchlist, store: SnapshotStore,
                          hiding openTargets: Set<String>) -> [CompanionAPI.WatchedSummary] {
        let hidden = Set(openTargets.map(TargetPath.normalise))
        return watchlist.targets.compactMap { target in
            let target = TargetPath.normalise(target)
            guard !hidden.contains(target) else { return nil }
            let newest = store.snapshots(forTarget: target).first
            return CompanionAPI.WatchedSummary(
                target: target,
                title: CompanionAPI.shortTitle(forPath: target),
                takenAt: newest?.takenAt,
                totalBytes: newest?.totalBytes ?? 0,
                totalHuman: ByteFormat.string(newest?.totalBytes ?? 0),
                fileCount: newest?.fileCount ?? 0)
        }
    }

    /// One folder of a snapshot, shaped like a tab's node so the phone can
    /// reuse the same screen. Colour, per-child file counts and by-type totals
    /// are what a snapshot does not keep, so they come out empty or guessed.
    static func node(target: String, path: String?, store: SnapshotStore,
                     limit: Int = LiveTabs.childLimit) -> CompanionAPI.Node? {
        let target = TargetPath.normalise(target)
        guard let snapshot = store.snapshots(forTarget: target).first else { return nil }
        let path = path.map(trimmed) ?? target
        guard let bytes = snapshot.bytes(forPath: path) else { return nil }

        let prefix = path.hasSuffix("/") ? path : path + "/"
        let children = snapshot.entries
            .filter { entry in
                guard entry.path.hasPrefix(prefix) else { return false }
                return !entry.path.dropFirst(prefix.count).contains("/")
            }
            .sorted { $0.bytes > $1.bytes }
        let shown = Array(children.prefix(max(0, limit)))

        return CompanionAPI.Node(
            tabID: target,
            path: path,
            name: path == target ? CompanionAPI.shortTitle(forPath: target)
                                 : URL(fileURLWithPath: path).lastPathComponent,
            bytes: bytes,
            isDirectory: path == target || snapshot.entries.contains {
                $0.path == path && $0.isDirectory
            },
            fileCount: path == target ? snapshot.fileCount : 0,
            directoryCount: children.filter(\.isDirectory).count,
            measure: (snapshot.measure ?? .physical).rawValue,
            breadcrumb: crumbs(target: target, path: path),
            children: shown.map { entry in
                CompanionAPI.NodeChild(
                    path: entry.path,
                    name: URL(fileURLWithPath: entry.path).lastPathComponent,
                    bytes: entry.bytes,
                    isDirectory: entry.isDirectory,
                    fileCount: 0,
                    share: bytes > 0 ? Double(entry.bytes) / Double(bytes) : 0,
                    family: family(of: entry),
                    modified: nil)
            },
            types: [],
            omittedChildren: children.count - shown.count)
    }

    private static func crumbs(target: String, path: String) -> [CompanionAPI.Crumb] {
        var crumbs = [CompanionAPI.Crumb(name: CompanionAPI.shortTitle(forPath: target),
                                         path: target)]
        guard path != target, path.hasPrefix(target == "/" ? "/" : target + "/") else {
            return crumbs
        }
        var current = target == "/" ? "" : target
        let rest = target == "/" ? String(path.dropFirst())
                                 : String(path.dropFirst(target.count + 1))
        for component in rest.split(separator: "/") {
            current += "/" + component
            crumbs.append(CompanionAPI.Crumb(name: String(component), path: current))
        }
        return crumbs
    }

    /// Directories have no stored family; files can still be coloured by name.
    private static func family(of entry: Snapshot.Entry) -> FileFamily {
        guard !entry.isDirectory else { return .other }
        let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        return FileFamily.of(extension: ext)
    }

    private static func trimmed(_ path: String) -> String {
        if path.count > 1, path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }
}
