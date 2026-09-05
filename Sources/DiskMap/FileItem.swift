import Foundation
import ReclaimKit

/// A node in the scanned file hierarchy.
///
/// Reference type on purpose: the tree is built by many threads, mutated when
/// files are deleted, and referenced by the treemap layout without copying.
final class FileItem {
    let name: String
    let isDirectory: Bool
    /// Logical size (`st_size`) for files, sum of children for directories.
    var logicalSize: UInt64
    /// Physical size on disk (`st_blocks` * 512), sum of children for directories.
    var physicalSize: UInt64
    var modified: Date
    var children: [FileItem]
    weak var parent: FileItem?
    /// Number of directories that could not be read (permission denied).
    var unreadableCount: Int = 0
    var fileCount: Int
    /// (device, inode) key for hard-link detection; nil unless st_nlink > 1.
    var linkKey: UInt64?

    init(name: String,
         isDirectory: Bool,
         logicalSize: UInt64 = 0,
         physicalSize: UInt64 = 0,
         modified: Date = .distantPast,
         fileCount: Int = 1,
         children: [FileItem] = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.logicalSize = logicalSize
        self.physicalSize = physicalSize
        self.modified = modified
        self.fileCount = fileCount
        self.children = children
        for child in children { child.parent = self }
    }

    func size(_ measure: SizeMeasure) -> UInt64 {
        measure == .physical ? physicalSize : logicalSize
    }

    /// Built by walking the parent chain and joining strings.
    ///
    /// Deliberately not via `URL(fileURLWithPath:)`: that form stats the file to
    /// decide whether it is a directory, and the sidebar asks for paths often
    /// enough (tooltips on every visible row) that it showed up as `lstat` in a
    /// profile of navigation.
    var path: String {
        var components: [String] = []
        var node: FileItem? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        // The root's name is an absolute path; the rest are path components.
        var path = components.removeLast()
        if path.hasSuffix("/") { path.removeLast() }
        for component in components.reversed() {
            path += "/" + component
        }
        return path
    }

    /// `isDirectory` is passed explicitly for the same reason: it is already
    /// known here, and supplying it keeps URL construction off the filesystem.
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    var depth: Int {
        var d = 0
        var node = parent
        while node != nil { d += 1; node = node!.parent }
        return d
    }

    /// File extension lowercased, or "" for none / directories.
    var ext: String {
        guard !isDirectory else { return "" }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Removes `child`, subtracting its size from every ancestor.
    func remove(child: FileItem) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        child.parent = nil
        let removedTotals = child.totals()
        var node: FileItem? = self
        while let current = node {
            current.logicalSize -= min(current.logicalSize, child.logicalSize)
            current.physicalSize -= min(current.physicalSize, child.physicalSize)
            current.fileCount -= child.fileCount
            if var totals = current.familyTotals {
                totals.subtract(removedTotals)
                current.familyTotals = totals
            }
            node = current.parent
        }
    }

    /// Stable identity for SwiftUI lists (the tree is made of reference types).
    var objectID: ObjectIdentifier { ObjectIdentifier(self) }

    /// Cached classification for a file; directories keep `familyTotals` instead.
    /// Filename parsing is expensive enough to have topped a profile, so it is
    /// done once, during the scan's aggregation pass.
    private var cachedFamily: FileFamily?

    /// Rolled-up per-family bytes and counts. Only directories carry one.
    private(set) var familyTotals: FamilyTotals?

    var family: FileFamily {
        if let cachedFamily { return cachedFamily }
        let resolved = FileFamily.of(self)
        cachedFamily = resolved
        return resolved
    }

    /// Per-family totals for everything at or below this node.
    ///
    /// Computed on first use and cached, so a folder is summed at most once no
    /// matter how often it is revisited, and a parent reuses what its children
    /// already worked out. Deriving these during the scan instead made scanning
    /// three times slower for work the user may never look at.
    func totals() -> FamilyTotals {
        if let familyTotals { return familyTotals }
        guard isDirectory else {
            return FamilyTotals(family: family, physical: physicalSize, logical: logicalSize)
        }
        var totals = FamilyTotals()
        for child in children { totals.add(child.totals()) }
        familyTotals = totals
        return totals
    }

    /// Drops the cached roll-up. Needed while a scan is running, where a
    /// folder's size changes under the summary that was derived from it.
    func invalidateTotals() {
        familyTotals = nil
    }

    /// Sums this subtree up front, off the main thread, so the first navigation
    /// after a scan is as cheap as every later one.
    func warmTotals() {
        _ = totals()
    }

    /// The kind of file this folder mostly holds, by bytes — the map colours a
    /// folder tile by its contents rather than painting every folder the same grey.
    func dominantFamily(_ measure: SizeMeasure) -> FileFamily {
        guard isDirectory else { return family }
        return totals().dominant(measure)
    }

    func isDescendant(of other: FileItem) -> Bool {
        var node: FileItem? = self
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }
}

enum SizeMeasure: String, CaseIterable, Codable {
    case physical, logical
    var label: String { self == .physical ? "Size on disk" : "Logical size" }
}
