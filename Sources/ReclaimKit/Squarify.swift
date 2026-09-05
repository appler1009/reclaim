import CoreGraphics
import Foundation

/// A squarified treemap of one level of children.
///
/// One level only, on purpose: the Mac app shows a folder as a single row of
/// labelled tiles rather than a mosaic, and the companion shows the same thing.
/// The Mac's own `TreemapLayout` recurses into a live tree of reference types
/// under a depth and area budget; this takes a list of weights and gives back
/// rectangles, which is all a client with a wire payload has to work with.
public enum Squarify {
    public struct Tile: Equatable, Sendable {
        /// Index into the weights that were passed in.
        public let index: Int
        public let rect: CGRect
    }

    /// Weights are used in the order given, so sort them largest-first before
    /// calling — that is what makes the tiles square rather than sliced.
    /// Non-positive weights are dropped; they have no area to occupy.
    public static func layout(weights: [Double], in bounds: CGRect) -> [Tile] {
        let entries = weights.enumerated().filter { $0.element > 0 }
        guard !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let total = entries.reduce(0) { $0 + $1.element }
        let scale = Double(bounds.width * bounds.height) / total

        var tiles: [Tile] = []
        tiles.reserveCapacity(entries.count)
        var remaining = bounds
        var index = 0

        while index < entries.count {
            let shortSide = Double(min(remaining.width, remaining.height))
            guard shortSide > 0 else { break }

            // Grow the row while adding the next tile makes the worst aspect
            // ratio in it better, and stop the moment it makes it worse.
            var row: [(offset: Int, element: Double)] = []
            var rowArea = 0.0
            var worst = Double.infinity
            var next = index
            while next < entries.count {
                let area = entries[next].element * scale
                let candidate = aspect(rowArea: rowArea + area,
                                       areas: row.map { $0.element * scale } + [area],
                                       side: shortSide)
                if !row.isEmpty && candidate > worst { break }
                row.append(entries[next])
                rowArea += area
                worst = candidate
                next += 1
            }

            remaining = place(row: row, area: rowArea, scale: scale, in: remaining, into: &tiles)
            index = next
        }
        return tiles
    }

    /// Lays one row along the shorter side and returns what is left over.
    private static func place(row: [(offset: Int, element: Double)], area: Double,
                              scale: Double, in bounds: CGRect,
                              into tiles: inout [Tile]) -> CGRect {
        guard area > 0 else { return bounds }
        let horizontal = bounds.width >= bounds.height
        let thickness = CGFloat(area / Double(horizontal ? bounds.height : bounds.width))
        var offset = horizontal ? bounds.minY : bounds.minX
        let span = horizontal ? bounds.height : bounds.width

        for (position, entry) in row.enumerated() {
            let length = CGFloat(entry.element * scale) / thickness
            // The last tile takes whatever rounding left behind, so a row has no
            // hairline gap at its end.
            let extent = position == row.count - 1
                ? max(0, (horizontal ? bounds.maxY : bounds.maxX) - offset)
                : min(length, span)
            let rect = horizontal
                ? CGRect(x: bounds.minX, y: offset, width: thickness, height: extent)
                : CGRect(x: offset, y: bounds.minY, width: extent, height: thickness)
            tiles.append(Tile(index: entry.offset, rect: rect))
            offset += extent
        }

        return horizontal
            ? CGRect(x: bounds.minX + thickness, y: bounds.minY,
                     width: max(0, bounds.width - thickness), height: bounds.height)
            : CGRect(x: bounds.minX, y: bounds.minY + thickness,
                     width: bounds.width, height: max(0, bounds.height - thickness))
    }

    /// The worst aspect ratio in a row of the given areas laid along `side`.
    private static func aspect(rowArea: Double, areas: [Double], side: Double) -> Double {
        guard rowArea > 0, side > 0, let largest = areas.max(), let smallest = areas.min(),
              smallest > 0 else { return .infinity }
        let side2 = side * side
        let area2 = rowArea * rowArea
        return max(side2 * largest / area2, area2 / (side2 * smallest))
    }
}
