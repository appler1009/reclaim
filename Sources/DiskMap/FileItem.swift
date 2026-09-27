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
    /// Seconds since 1970. A `Date` on every node is a second word the scan
    /// never needs until a row asks for it; 0 stands in for "unknown".
    private var modifiedSeconds: UInt32 = 0
    var modified: Date {
        get {
            modifiedSeconds == 0
                ? .distantPast
                : Date(timeIntervalSince1970: TimeInterval(modifiedSeconds))
        }
        set {
            let seconds = newValue.timeIntervalSince1970
            modifiedSeconds = seconds <= 0 ? 0 : UInt32(min(seconds, Double(UInt32.max)))
        }
    }
    var children: [FileItem]
    weak var parent: FileItem?
    /// Number of directories that could not be read (permission denied).
    private var unreadableStorage: Int32 = 0
    var unreadableCount: Int {
        get { Int(unreadableStorage) }
        set { unreadableStorage = Int32(clamping: newValue) }
    }
    private var fileCountStorage: Int32
    var fileCount: Int {
        get { Int(fileCountStorage) }
        set { fileCountStorage = Int32(clamping: newValue) }
    }
    /// Children were not kept. The sizes are the whole subtree; opening the
    /// folder reads it from disk.
    var isFolded = false
    /// Stands in for the files in this folder that were too small to keep.
    /// It is not a path on disk.
    var representsSmallFiles = false

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
        self.fileCountStorage = Int32(clamping: fileCount)
        self.children = children
        self.modified = modified
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
        let origin: FileItem? = representsSmallFiles ? parent : self
        guard var node = origin else { return "" }
        var components: [String] = []
        while true {
            if !node.representsSmallFiles {
                components.append(node.name)
            }
            guard let parent = node.parent else { break }
            node = parent
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

    /// One object rather than the struct inline: an optional `FamilyTotals`
    /// is large enough that storing it in the node would tax every file, and
    /// most files never have one. Directories that cache a roll-up pay for a
    /// single box, not three arrays.
    private final class TotalsBox {
        var value: FamilyTotals
        init(_ value: FamilyTotals) { self.value = value }
    }
    private var totalsBox: TotalsBox?

    /// Rolled-up per-family bytes and counts. Only directories carry one.
    private(set) var familyTotals: FamilyTotals? {
        get { totalsBox?.value }
        set {
            if let newValue {
                if let totalsBox {
                    totalsBox.value = newValue
                } else {
                    totalsBox = TotalsBox(newValue)
                }
            } else {
                totalsBox = nil
            }
        }
    }

    var family: FileFamily {
        if let cachedFamily { return cachedFamily }
        let resolved = FileFamily.of(self)
        cachedFamily = resolved
        return resolved
    }

    /// Per-family totals for everything at or below this node.
    ///
    /// Cached on this node only. Descendants keep a cache when something asked
    /// them directly — the folder on screen, the two levels under it after a
    /// scan — and otherwise are summed and forgotten. Caching every directory
    /// made the first navigation cheap and left a roll-up on folders nobody
    /// opened.
    func totals() -> FamilyTotals {
        if let familyTotals { return familyTotals }
        guard isDirectory else { return ownTotals }
        var totals = FamilyTotals()
        for child in children { totals.add(child.summed()) }
        familyTotals = totals
        return totals
    }

    /// This node's roll-up, reusing a cache a parent already paid for and not
    /// storing one where there is none.
    private func summed() -> FamilyTotals {
        if let familyTotals { return familyTotals }
        guard isDirectory else { return ownTotals }
        var totals = FamilyTotals()
        for child in children { totals.add(child.summed()) }
        return totals
    }

    private var ownTotals: FamilyTotals {
        FamilyTotals(family: family, physical: physicalSize, logical: logicalSize)
    }

    /// Drops the cached roll-up. Needed while a scan is running, where a
    /// folder's size changes under the summary that was derived from it.
    func invalidateTotals() {
        familyTotals = nil
    }

    /// Installs totals a walk already computed, for a folded folder or the
    /// small-files row, neither of which has children to sum.
    func adopt(_ totals: FamilyTotals) {
        familyTotals = totals
    }

    func carriedTotals() -> FamilyTotals? { familyTotals }

    /// Caches roll-ups for this node and `depth` levels under it.
    ///
    /// The folder a scan lands on, and the ones a single click away, are the
    /// ones the sidebar asks about. Deeper folders sum themselves when opened.
    func warmTotals(through depth: Int = 2) {
        _ = warm(depth)
    }

    private func warm(_ depth: Int) -> FamilyTotals {
        if let familyTotals { return familyTotals }
        guard isDirectory else { return ownTotals }
        var totals = FamilyTotals()
        for child in children {
            if depth > 0, child.isDirectory {
                totals.add(child.warm(depth - 1))
            } else {
                totals.add(child.summed())
            }
        }
        familyTotals = totals
        return totals
    }

    /// The kind of file this folder mostly holds, by bytes — the map colours a
    /// folder tile by its contents rather than painting every folder the same grey.
    func dominantFamily(_ measure: SizeMeasure) -> FileFamily {
        if representsSmallFiles { return totals().dominant(measure) }
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
