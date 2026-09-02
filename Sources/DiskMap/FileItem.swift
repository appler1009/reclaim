import Foundation

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

    var url: URL {
        var components: [String] = []
        var node: FileItem? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        components.reverse()
        // The root's name is an absolute path; the rest are path components.
        var url = URL(fileURLWithPath: components[0], isDirectory: true)
        for component in components.dropFirst() {
            url.appendPathComponent(component)
        }
        return url
    }

    var path: String { url.path }

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
        invalidateDominantFamily()
        children.remove(at: index)
        child.parent = nil
        var node: FileItem? = self
        while let current = node {
            current.logicalSize -= min(current.logicalSize, child.logicalSize)
            current.physicalSize -= min(current.physicalSize, child.physicalSize)
            current.fileCount -= child.fileCount
            node = current.parent
        }
    }

    /// Stable identity for SwiftUI lists (the tree is made of reference types).
    var objectID: ObjectIdentifier { ObjectIdentifier(self) }

    private var dominantFamilyCache: FileFamily?

    /// The kind of file this folder mostly holds, by bytes — the map colours a
    /// folder tile by its contents rather than painting every folder the same
    /// grey. Walked once per folder and cached; the map redraws constantly.
    func dominantFamily(_ measure: SizeMeasure) -> FileFamily {
        if let dominantFamilyCache { return dominantFamilyCache }
        guard isDirectory else {
            let family = FileFamily.of(self)
            dominantFamilyCache = family
            return family
        }
        var bytesByFamily: [FileFamily: UInt64] = [:]
        var stack: [FileItem] = [self]
        while let current = stack.popLast() {
            if current.isDirectory {
                stack.append(contentsOf: current.children)
            } else {
                let size = current.size(measure)
                if size > 0 { bytesByFamily[FileFamily.of(current), default: 0] += size }
            }
        }
        let family = bytesByFamily.max { $0.value < $1.value }?.key ?? .other
        dominantFamilyCache = family
        return family
    }

    private func invalidateDominantFamily() {
        var node: FileItem? = self
        while let current = node {
            current.dominantFamilyCache = nil
            node = current.parent
        }
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

enum SizeMeasure: String, CaseIterable {
    case physical, logical
    var label: String { self == .physical ? "Size on disk" : "Logical size" }
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}
