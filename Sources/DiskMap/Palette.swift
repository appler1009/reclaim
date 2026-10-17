import AppKit
import ReclaimKit

/// How a file family is drawn on the Mac. The families themselves, and the
/// colours as plain components, live in `ReclaimKit` so the companion app
/// paints the same tiles.
extension FileFamily {
    static func of(_ item: FileItem) -> FileFamily {
        item.isDirectory ? .other : of(extension: item.ext)
    }

    var color: NSColor {
        let (red, green, blue) = rgb
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

enum Theme {
    static let background = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.086, alpha: 1)
    static let panel = NSColor(srgbRed: 0.086, green: 0.098, blue: 0.129, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.08)
    static let accent = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1)
}

/// Where a tile stands on the city map.
extension District {
    /// The district for `item`. `ancestors` are the names of the folders above
    /// it, nearest first; a layout works them out once for the folder in view.
    static func of(_ item: FileItem, measure: SizeMeasure, ancestors: [String]) -> District {
        let family = item.dominantFamily(measure)
        // The small-files bundle stands in for many files and has no real name.
        if item.representsSmallFiles {
            return classify(DistrictClue(name: "", isDirectory: false, ext: "", family: family,
                                         bytes: item.size(measure), fileCount: item.fileCount,
                                         ancestors: ancestors))
        }
        let hasGit = item.isDirectory && item.children.contains { $0.isDirectory && $0.name == ".git" }
        return classify(DistrictClue(name: item.name, isDirectory: item.isDirectory, ext: item.ext,
                                     family: family, bytes: item.size(measure),
                                     fileCount: item.fileCount, modified: item.modified,
                                     hasGitFolder: hasGit, ancestors: ancestors))
    }
}

extension FileItem {
    /// Names of the folders above this one, nearest first.
    var ancestorNames: [String] {
        var names: [String] = []
        var node = parent
        while let current = node {
            if !current.representsSmallFiles { names.append(current.name) }
            node = current.parent
        }
        return names
    }
}

extension TreemapLayout {
    /// The district of every cell, in cell order. Done once per layout, on the
    /// main thread (the family roll-ups it reads are cached on the nodes).
    func zoned(_ measure: SizeMeasure) -> [District] {
        guard let root else { return [] }
        let above = [root.name] + root.ancestorNames
        return cells.map { cell in
            if cell.item === root {
                return District.of(cell.item, measure: measure, ancestors: root.ancestorNames)
            }
            var chain: [String] = []
            var node = cell.item.parent
            while let current = node, current !== root {
                chain.append(current.name)
                node = current.parent
            }
            return District.of(cell.item, measure: measure, ancestors: chain + above)
        }
    }
}
