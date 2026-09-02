import AppKit

/// Draws a laid-out treemap into a context.
///
/// Split out of the view so it can be measured off-screen: rendering a
/// full-detail map is the other half of the resize budget, next to layout.
enum TreemapRenderer {
    /// Colour per family, resolved once — `NSColor.blended` allocates, and doing
    /// it per cell showed up as pure overhead for ~100k cells.
    private static let shades: [[CGColor]] = FileFamily.allCases.map { family in
        (0 ... 7).map { step in
            let shade = min(CGFloat(step) * 0.045, 0.30)
            return (family.color.blended(withFraction: shade, of: .black) ?? family.color).cgColor
        }
    }
    private static let stagedShades: [CGColor] = FileFamily.allCases.map { family in
        (family.color.blended(withFraction: 0.45, of: Theme.accent) ?? family.color).cgColor
    }
    /// The exact colour a tile is painted, so labels can pick a contrasting ink.
    static func tileColor(family: FileFamily, depth: Int32, staged: Bool) -> NSColor {
        let base = family.color
        if staged { return base.blended(withFraction: 0.45, of: Theme.accent) ?? base }
        let shade = min(CGFloat(depth) * 0.045, 0.30)
        return base.blended(withFraction: shade, of: .black) ?? base
    }

    /// Perceived brightness, for deciding between light and dark label text.
    static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.62
    }

    private static let highlight = NSColor(white: 1, alpha: 0.10).cgColor
    private static let shadow = NSColor(white: 0, alpha: 0.28).cgColor

    static func draw(layout: TreemapLayout,
                     in context: CGContext,
                     dirty: CGRect,
                     measure: SizeMeasure,
                     staged: Set<ObjectIdentifier>) {
        context.setFillColor(Theme.background.cgColor)
        context.fill(dirty)

        for cell in layout.cells {
            let rect = cell.rect
            guard rect.width > 0.3, rect.height > 0.3, rect.intersects(dirty) else { continue }
            // Folders are coloured by what they mostly contain.
            let familyIndex = cell.item.dominantFamily(measure).index
            let isStaged = !staged.isEmpty && staged.contains(ObjectIdentifier(cell.item))

            context.setFillColor(isStaged
                                 ? stagedShades[familyIndex]
                                 : shades[familyIndex][min(Int(cell.depth), 7)])
            context.fill(rect)

            // Shading lives inside the tile, so tiles still meet edge to edge.
            // Only worth drawing where it is actually visible.
            if rect.width > 5 && rect.height > 5 {
                context.setFillColor(highlight)
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
                context.setFillColor(shadow)
                context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
                context.fill(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height))
            }
            if isStaged && rect.width > 8 && rect.height > 8 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(1.5)
                context.stroke(rect.insetBy(dx: 1, dy: 1))
            }
        }

        // Folder boundaries are strokes over the tiles, never gaps between them.
        context.setLineWidth(1)
        for frame in layout.folderFrames
        where frame.rect.width > 12 && frame.rect.height > 12 && frame.rect.intersects(dirty) {
            let alpha = max(0.05, 0.34 - CGFloat(frame.depth) * 0.06)
            context.setStrokeColor(NSColor(white: 0, alpha: alpha).cgColor)
            context.stroke(frame.rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
