import CoreGraphics
import Foundation
import Testing
@testable import DiskMap

@Suite("Treemap layout")
struct TreemapTests {
    private let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)

    /// Builds a tree directly, so layout tests do not depend on the filesystem.
    private func tree(_ sizes: [UInt64], name: String = "root") -> FileItem {
        let children = sizes.enumerated().map { index, size in
            FileItem(name: "child-\(index)", isDirectory: false,
                     logicalSize: size, physicalSize: size)
        }
        let root = FileItem(name: name, isDirectory: true, children: children)
        root.physicalSize = sizes.reduce(0, +)
        root.logicalSize = root.physicalSize
        root.children.sort { $0.physicalSize > $1.physicalSize }
        return root
    }

    @Test func cellsTileTheBoundsWithoutGaps() {
        let layout = TreemapLayout.build(root: tree([500, 300, 120, 60, 15, 5]),
                                         in: bounds, measure: .physical, maximumDepth: 1)
        let covered = layout.cells.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        let total = Double(bounds.width * bounds.height)
        #expect(abs(covered - total) / total < 0.001, "cells covered \(covered) of \(total)")
    }

    @Test func everyPointBelongsToExactlyOneCell() {
        let layout = TreemapLayout.build(root: tree([900, 450, 210, 130, 70, 40, 20, 9, 3]),
                                         in: bounds, measure: .physical, maximumDepth: 1)
        var uncovered = 0
        var overlapping = 0
        for x in stride(from: 0.5, to: bounds.width, by: 7) {
            for y in stride(from: 0.5, to: bounds.height, by: 7) {
                let point = CGPoint(x: x, y: y)
                let hits = layout.cells.filter { $0.rect.contains(point) }.count
                if hits == 0 { uncovered += 1 }
                if hits > 1 { overlapping += 1 }
            }
        }
        #expect(uncovered == 0, "\(uncovered) sample points fell in a gap")
        #expect(overlapping == 0, "\(overlapping) sample points were covered twice")
    }

    @Test func areaIsProportionalToSize() {
        let root = tree([600, 300, 100])
        let layout = TreemapLayout.build(root: root, in: bounds, measure: .physical, maximumDepth: 1)
        let total = Double(bounds.width * bounds.height)
        for cell in layout.cells {
            let expected = Double(cell.item.physicalSize) / 1000 * total
            let actual = Double(cell.rect.width * cell.rect.height)
            #expect(abs(actual - expected) / expected < 0.02,
                    "\(cell.item.name): \(actual) vs expected \(expected)")
        }
    }

    @Test func oneLevelLayoutStopsAtImmediateChildren() {
        let inner = tree([100, 60, 40], name: "inner")
        let outer = FileItem(name: "outer", isDirectory: true, children: [inner])
        outer.physicalSize = inner.physicalSize
        let layout = TreemapLayout.build(root: outer, in: bounds, measure: .physical, maximumDepth: 1)
        #expect(layout.cells.count == 1)
        #expect(layout.cells.first?.item === inner)
        #expect(layout.cells.first?.collapsed == true)
    }

    @Test func hitTestingFindsTheCellUnderAPoint() {
        let layout = TreemapLayout.build(root: tree([700, 200, 100]),
                                         in: bounds, measure: .physical, maximumDepth: 1)
        let cell = try? #require(layout.cells.first)
        let middle = CGPoint(x: cell!.rect.midX, y: cell!.rect.midY)
        #expect(layout.item(at: middle)?.item === cell!.item)
        #expect(layout.item(at: CGPoint(x: -5, y: -5)) == nil)
    }

    @Test func zeroSizedChildrenAreLeftOut() {
        let layout = TreemapLayout.build(root: tree([500, 0, 250, 0]),
                                         in: bounds, measure: .physical, maximumDepth: 1)
        #expect(layout.cells.count == 2)
        #expect(layout.cells.allSatisfy { $0.item.physicalSize > 0 })
    }

    @Test func emptyBoundsProduceNoCells() {
        let layout = TreemapLayout.build(root: tree([100]), in: .zero, measure: .physical)
        #expect(layout.cells.isEmpty)
    }

    @Test func deepLayoutCollapsesFoldersTooSmallToShow() {
        // 400 children inside a sliver: expanding them would draw sub-pixel specks.
        let crowded = tree(Array(repeating: UInt64(10), count: 400), name: "crowded")
        let root = FileItem(name: "root", isDirectory: true,
                            children: [crowded,
                                       FileItem(name: "whale", isDirectory: false,
                                                logicalSize: 4_000_000, physicalSize: 4_000_000)])
        root.physicalSize = crowded.physicalSize + 4_000_000
        root.children.sort { $0.physicalSize > $1.physicalSize }

        let layout = TreemapLayout.build(root: root, in: bounds, measure: .physical, maximumDepth: 8)
        #expect(layout.cells.count < 50, "expanded \(layout.cells.count) unreadable cells")
    }
}
