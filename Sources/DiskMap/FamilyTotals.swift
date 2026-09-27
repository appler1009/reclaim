import Foundation
import ReclaimKit

/// Bytes and file counts per file family, rolled up for a folder.
///
/// Kept on directories the interface is likely to show, so the sidebar's
/// by-type summary and a folder tile's colour are lookups instead of subtree
/// walks. The slots are inline: the previous form was three heap arrays per
/// folder, and every file built a throwaway set of those while a parent summed
/// itself.
struct FamilyTotals {
    private var physicalSlots = Slots()
    private var logicalSlots = Slots()
    private var countSlots = CountSlots()

    static let slots = FileFamily.allCases.count

    init() {}

    init(family: FileFamily, physical physicalSize: UInt64, logical logicalSize: UInt64) {
        let slot = family.index
        physicalSlots[slot] = physicalSize
        logicalSlots[slot] = logicalSize
        countSlots[slot] = 1
    }

    func bytes(_ measure: SizeMeasure) -> [UInt64] {
        let source = measure == .physical ? physicalSlots : logicalSlots
        return (0 ..< Self.slots).map { source[$0] }
    }

    var counts: [Int32] {
        (0 ..< Self.slots).map { countSlots[$0] }
    }

    mutating func add(_ other: FamilyTotals) {
        for slot in 0 ..< Self.slots {
            physicalSlots[slot] &+= other.physicalSlots[slot]
            logicalSlots[slot] &+= other.logicalSlots[slot]
            countSlots[slot] += other.countSlots[slot]
        }
    }

    mutating func subtract(_ other: FamilyTotals) {
        for slot in 0 ..< Self.slots {
            physicalSlots[slot] -= min(physicalSlots[slot], other.physicalSlots[slot])
            logicalSlots[slot] -= min(logicalSlots[slot], other.logicalSlots[slot])
            countSlots[slot] = max(0, countSlots[slot] - other.countSlots[slot])
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

    /// Nine `UInt64`s, stored in the struct rather than on the heap.
    private struct Slots {
        var v0: UInt64 = 0, v1: UInt64 = 0, v2: UInt64 = 0
        var v3: UInt64 = 0, v4: UInt64 = 0, v5: UInt64 = 0
        var v6: UInt64 = 0, v7: UInt64 = 0, v8: UInt64 = 0

        subscript(index: Int) -> UInt64 {
            get {
                switch index {
                case 0: return v0
                case 1: return v1
                case 2: return v2
                case 3: return v3
                case 4: return v4
                case 5: return v5
                case 6: return v6
                case 7: return v7
                default: return v8
                }
            }
            set {
                switch index {
                case 0: v0 = newValue
                case 1: v1 = newValue
                case 2: v2 = newValue
                case 3: v3 = newValue
                case 4: v4 = newValue
                case 5: v5 = newValue
                case 6: v6 = newValue
                case 7: v7 = newValue
                default: v8 = newValue
                }
            }
        }
    }

    private struct CountSlots {
        var v0: Int32 = 0, v1: Int32 = 0, v2: Int32 = 0
        var v3: Int32 = 0, v4: Int32 = 0, v5: Int32 = 0
        var v6: Int32 = 0, v7: Int32 = 0, v8: Int32 = 0

        subscript(index: Int) -> Int32 {
            get {
                switch index {
                case 0: return v0
                case 1: return v1
                case 2: return v2
                case 3: return v3
                case 4: return v4
                case 5: return v5
                case 6: return v6
                case 7: return v7
                default: return v8
                }
            }
            set {
                switch index {
                case 0: v0 = newValue
                case 1: v1 = newValue
                case 2: v2 = newValue
                case 3: v3 = newValue
                case 4: v4 = newValue
                case 5: v5 = newValue
                case 6: v6 = newValue
                case 7: v7 = newValue
                default: v8 = newValue
                }
            }
        }
    }
}
