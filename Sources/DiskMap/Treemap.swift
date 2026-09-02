import CoreGraphics
import Foundation

struct TreemapCell {
    let item: FileItem
    let rect: CGRect
    let depth: Int
    /// True when the cell stands in for a whole directory that was too small to expand.
    let collapsed: Bool
}

/// A squarified treemap layout of a `FileItem` subtree.
struct TreemapLayout {
    var cells: [TreemapCell] = []
    /// Frames of the directories that were expanded, for drawing nesting outlines.
    var folderFrames: [(rect: CGRect, depth: Int)] = []
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
                      maximumDepth: Int = 64) -> TreemapLayout {
        var layout = TreemapLayout()
        layout.root = root
        layout.bounds = bounds
        guard bounds.width > 1, bounds.height > 1 else { return layout }
        layout.place(item: root, rect: bounds, depth: 0, measure: measure,
                     minimumArea: minimumArea, maximumDepth: maximumDepth)
        return layout
    }

    private mutating func place(item: FileItem,
                                rect: CGRect,
                                depth: Int,
                                measure: SizeMeasure,
                                minimumArea: CGFloat,
                                maximumDepth: Int) {
        let area = rect.width * rect.height
        let expandable = item.isDirectory
            && !item.children.isEmpty
            && item.size(measure) > 0
            && area >= minimumArea * 4
            && depth < maximumDepth

        guard expandable else {
            cells.append(TreemapCell(item: item, rect: rect, depth: depth,
                                     collapsed: item.isDirectory))
            return
        }

        folderFrames.append((rect, depth))
        // Inset so nested folders read as containers, but never collapse the box.
        let inset: CGFloat = (rect.width > 6 && rect.height > 6) ? 1 : 0
        let inner = rect.insetBy(dx: inset, dy: inset)

        let children = item.children
            .filter { $0.size(measure) > 0 }
            .sorted { $0.size(measure) > $1.size(measure) }
        guard !children.isEmpty else {
            cells.append(TreemapCell(item: item, rect: rect, depth: depth, collapsed: true))
            return
        }

        let total = children.reduce(UInt64(0)) { $0 + $1.size(measure) }
        squarify(children: children,
                 total: total,
                 rect: inner,
                 measure: measure) { child, childRect in
            self.place(item: child, rect: childRect, depth: depth + 1, measure: measure,
                       minimumArea: minimumArea, maximumDepth: maximumDepth)
        }
    }

    /// Squarified treemap (Bruls, Huizing & van Wijk): fills the rect with rows of
    /// cells chosen to keep aspect ratios as close to square as possible.
    private func squarify(children: [FileItem],
                          total: UInt64,
                          rect: CGRect,
                          measure: SizeMeasure,
                          emit: (FileItem, CGRect) -> Void) {
        var remaining = rect
        var remainingValue = Double(total)
        var index = 0

        while index < children.count, remaining.width > 0.01, remaining.height > 0.01 {
            let shortSide = min(remaining.width, remaining.height)
            let scale = (remaining.width * remaining.height) / max(remainingValue, 1)

            var rowValue = 0.0
            var rowCount = 0
            var rowMin = Double.greatestFiniteMagnitude
            var rowMax = 0.0
            var bestRatio = Double.greatestFiniteMagnitude

            while index + rowCount < children.count {
                let value = Double(children[index + rowCount].size(measure))
                let ratio = worstRatio(rowValue: rowValue + value,
                                       rowMin: min(rowMin, value),
                                       rowMax: max(rowMax, value),
                                       shortSide: Double(shortSide),
                                       scale: Double(scale))
                if rowCount > 0 && ratio > bestRatio { break }
                bestRatio = ratio
                rowValue += value
                rowMin = min(rowMin, value)
                rowMax = max(rowMax, value)
                rowCount += 1
            }
            if rowCount == 0 { rowCount = 1; rowValue = Double(children[index].size(measure)) }

            let row = Array(children[index ..< index + rowCount])
            let rowArea = CGFloat(rowValue) * scale
            let horizontal = remaining.width >= remaining.height
            let thickness = min(horizontal ? remaining.height : remaining.width,
                                shortSide > 0 ? rowArea / shortSide : 0)

            var offset: CGFloat = 0
            for (position, child) in row.enumerated() {
                let share = rowValue > 0 ? CGFloat(Double(child.size(measure)) / rowValue) : 0
                var length = share * shortSide
                if position == row.count - 1 { length = shortSide - offset }
                let cell: CGRect
                if horizontal {
                    cell = CGRect(x: remaining.minX, y: remaining.minY + offset,
                                  width: thickness, height: length)
                } else {
                    cell = CGRect(x: remaining.minX + offset, y: remaining.minY,
                                  width: length, height: thickness)
                }
                if cell.width > 0.02 && cell.height > 0.02 { emit(child, cell) }
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
