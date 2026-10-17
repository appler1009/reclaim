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
    static func of(_ item: FileItem, family: FileFamily, insideReclaimable: Bool) -> District {
        // The small-files bundle is a stand-in, not a folder with a name of its own.
        if item.representsSmallFiles { return zoned(family) }
        return of(name: item.name, isDirectory: item.isDirectory, ext: item.ext,
                  family: family, insideReclaimable: insideReclaimable)
    }
}

extension FileItem {
    /// Named like something that is rebuilt on demand: a cache, build output, logs.
    var isReclaimableByName: Bool {
        !representsSmallFiles && District.isReclaimable(name: name, isDirectory: isDirectory, ext: ext)
    }

    /// This item, or a folder it sits in, is rebuildable.
    var isWithinReclaimable: Bool {
        var node: FileItem? = self
        while let current = node {
            if current.isReclaimableByName { return true }
            node = current.parent
        }
        return false
    }
}
