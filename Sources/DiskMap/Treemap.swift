import CoreGraphics
import Foundation

struct TreemapCell {
    /// Not retained: the layout never outlives the tree it describes, and
    /// retain/release on ~100k cells was the single biggest cost in the
    /// profile of a full-detail layout.
    unowned(unsafe) let item: FileItem
    let rect: CGRect
    let depth: Int32
    /// True when the cell stands in for a whole directory that was too small to expand.
    let collapsed: Bool
}

/// A squarified treemap layout of a `FileItem` subtree.
struct TreemapLayout {
    var cells: [TreemapCell] = []
    /// Frames of the directories that were expanded, for drawing nesting outlines.
    var folderFrames: [(rect: CGRect, depth: Int32)] = []
    private(set) var root: FileItem?
    private(set) var bounds: CGRect = .zero

    /// Cells are laid out largest-first, so a reverse scan finds the innermost hit.
    func item(at point: CGPoint) -> TreemapCell? {
        for cell in cells.reversed() where cell.rect.contains(point) {
            return cell
        }
        return nil
    }

    static func build(root: FileItem,
                      in bounds: CGRect,
                      measure: SizeMeasure,
                      minimumArea: CGFloat = 16,
                      maximumDepth: Int32 = 64) -> TreemapLayout {
        var layout = TreemapLayout()
        layout.root = root
        layout.bounds = bounds
        guard bounds.width > 1, bounds.height > 1 else { return layout }

        let builder = TreemapBuilder(measure: measure,
                                     minimumArea: minimumArea,
                                     maximumDepth: maximumDepth)
        builder.place(item: root, rect: bounds, depth: 0)
        layout.cells = builder.cells
        layout.folderFrames = builder.folderFrames
        return layout
    }
}

/// Builds the cell list.
///
/// Deliberately a class: as a struct, every recursive `place` call made from
/// inside `squarify`'s closure copied the growing cell arrays, and the copies
/// (plus their ARC traffic) cost more than the layout maths itself.
private final class TreemapBuilder {
    private(set) var cells: [TreemapCell] = []
    private(set) var folderFrames: [(rect: CGRect, depth: Int32)] = []

    private let measure: SizeMeasure
    private let minimumArea: CGFloat
    private let maximumDepth: Int32
    /// Average on-screen area a child must be able to occupy before its parent
    /// is expanded, in square points.
    static let minimumChildArea: CGFloat = 3

    init(measure: SizeMeasure, minimumArea: CGFloat, maximumDepth: Int32) {
        self.measure = measure
        self.minimumArea = minimumArea
        self.maximumDepth = maximumDepth
        cells.reserveCapacity(4096)
        folderFrames.reserveCapacity(512)
    }

    func place(item: FileItem, rect: CGRect, depth: Int32) {
        let area = rect.width * rect.height
        // Expanding a folder whose children would land on a fraction of a pixel
        // each costs real time and shows nothing, so it stays a single tile.
        let expandable = item.isDirectory
            && !item.children.isEmpty
            && item.size(measure) > 0
            && area >= minimumArea * 4
            && area >= CGFloat(item.children.count) * TreemapBuilder.minimumChildArea
            && depth < maximumDepth

        guard expandable else {
            cells.append(TreemapCell(item: item, rect: rect, depth: depth,
                                     collapsed: item.isDirectory))
            return
        }

        folderFrames.append((rect, depth))

        // Children are kept sorted largest-first by the model, so the layout
        // neither sorts nor allocates here; zero-sized entries sort to the end.
        let children = item.children
        var count = children.count
        while count > 0, children[count - 1].size(measure) == 0 { count -= 1 }
        guard count > 0 else {
            cells.append(TreemapCell(item: item, rect: rect, depth: depth, collapsed: true))
            return
        }

        var total: UInt64 = 0
        for index in 0 ..< count { total &+= children[index].size(measure) }
        // No inset: children tile their parent exactly, so the map has no gaps.
        squarify(children: children, count: count, total: total, rect: rect, depth: depth)
    }

    /// Squarified treemap (Bruls, Huizing & van Wijk): fills the rect with rows of
    /// cells chosen to keep aspect ratios as close to square as possible.
    private func squarify(children: [FileItem],
                          count: Int,
                          total: UInt64,
                          rect: CGRect,
                          depth: Int32) {
        var remaining = rect
        var remainingValue = Double(total)
        var index = 0

        while index < count, remaining.width > 0.01, remaining.height > 0.01 {
            let shortSide = Double(min(remaining.width, remaining.height))
            let scale = Double(remaining.width * remaining.height) / max(remainingValue, 1)

            var rowValue = 0.0
            var rowCount = 0
            var rowMin = Double.greatestFiniteMagnitude
            var rowMax = 0.0
            var bestRatio = Double.greatestFiniteMagnitude

            while index + rowCount < count {
                let value = Double(children[index + rowCount].size(measure))
                let ratio = worstRatio(rowValue: rowValue + value,
                                       rowMin: min(rowMin, value),
                                       rowMax: max(rowMax, value),
                                       shortSide: shortSide,
                                       scale: scale)
                if rowCount > 0 && ratio > bestRatio { break }
                bestRatio = ratio
                rowValue += value
                rowMin = min(rowMin, value)
                rowMax = max(rowMax, value)
                rowCount += 1
            }
            if rowCount == 0 {
                rowCount = 1
                rowValue = Double(children[index].size(measure))
            }

            let rowArea = CGFloat(rowValue * scale)
            // A row is a strip cut off the long side, laid out along the short one.
            let horizontal = remaining.width >= remaining.height
            let available = horizontal ? remaining.width : remaining.height
            var thickness = min(available, shortSide > 0 ? rowArea / CGFloat(shortSide) : 0)
            // The last row takes whatever is left, so the parent is tiled exactly
            // and no sliver of background shows through between cells.
            if index + rowCount >= count { thickness = available }

            var offset: CGFloat = 0
            for position in 0 ..< rowCount {
                let child = children[index + position]
                let share = rowValue > 0 ? CGFloat(Double(child.size(measure)) / rowValue) : 0
                var length = share * CGFloat(shortSide)
                if position == rowCount - 1 { length = CGFloat(shortSide) - offset }
                let cell: CGRect
                if horizontal {
                    cell = CGRect(x: remaining.minX, y: remaining.minY + offset,
                                  width: thickness, height: length)
                } else {
                    cell = CGRect(x: remaining.minX + offset, y: remaining.minY,
                                  width: length, height: thickness)
                }
                if cell.width > 0.02 && cell.height > 0.02 {
                    place(item: child, rect: cell, depth: depth + 1)
                }
                offset += length
            }

            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            remainingValue -= rowValue
            index += rowCount
        }
    }

    private func worstRatio(rowValue: Double,
                            rowMin: Double,
                            rowMax: Double,
                            shortSide: Double,
                            scale: Double) -> Double {
        guard rowValue > 0, shortSide > 0, rowMin > 0 else { return .greatestFiniteMagnitude }
        // Row thickness if this row were closed off now.
        let thickness = rowValue * scale / shortSide
        guard thickness > 0 else { return .greatestFiniteMagnitude }
        // Aspect ratio of the worst cell in the row: max(t²/minArea, maxArea/t²).
        let squareT = thickness * thickness
        return max(squareT / (rowMin * scale), (rowMax * scale) / squareT)
    }
}
