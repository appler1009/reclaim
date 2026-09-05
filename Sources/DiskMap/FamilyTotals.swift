import Foundation
import ReclaimKit

/// Bytes and file counts per file family, rolled up for a folder.
///
/// Kept on every directory so the sidebar's by-type summary and a folder tile's
/// colour are lookups instead of subtree walks. Before this, navigating into a
/// large folder re-classified every file underneath it — filename parsing in
/// `FileFamily.of` was the top of the profile, and the worst navigation step
/// took 88 ms.
struct FamilyTotals {
    private(set) var physical: [UInt64]
    private(set) var logical: [UInt64]
    private(set) var counts: [Int32]

    static let slots = FileFamily.allCases.count

    init() {
        physical = [UInt64](repeating: 0, count: Self.slots)
        logical = [UInt64](repeating: 0, count: Self.slots)
        counts = [Int32](repeating: 0, count: Self.slots)
    }

    init(family: FileFamily, physical physicalSize: UInt64, logical logicalSize: UInt64) {
        self.init()
        let slot = family.index
        physical[slot] = physicalSize
        logical[slot] = logicalSize
        counts[slot] = 1
    }

    func bytes(_ measure: SizeMeasure) -> [UInt64] {
        measure == .physical ? physical : logical
    }

    mutating func add(_ other: FamilyTotals) {
        for slot in 0 ..< Self.slots {
            physical[slot] &+= other.physical[slot]
            logical[slot] &+= other.logical[slot]
            counts[slot] += other.counts[slot]
        }
    }

    mutating func subtract(_ other: FamilyTotals) {
        for slot in 0 ..< Self.slots {
            physical[slot] -= min(physical[slot], other.physical[slot])
            logical[slot] -= min(logical[slot], other.logical[slot])
            counts[slot] = max(0, counts[slot] - other.counts[slot])
        }
    }

    /// The family holding the most bytes, which is how a folder tile is coloured.
    func dominant(_ measure: SizeMeasure) -> FileFamily {
        let values = bytes(measure)
        var best = 0
        var bestValue: UInt64 = 0
        for slot in 0 ..< Self.slots where values[slot] > bestValue {
            bestValue = values[slot]
            best = slot
        }
        return bestValue == 0 ? .other : FileFamily.allCases[best]
    }
}
