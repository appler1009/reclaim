import Foundation

/// One row of the "what is in here" list: a direct child of the folder being
/// viewed, with its share of that folder.
struct BreakdownRow: Identifiable {
    let node: FileItem
    let bytes: UInt64
    let share: Double

    var id: ObjectIdentifier { ObjectIdentifier(node) }
    var name: String { node.name }
    var isDirectory: Bool { node.isDirectory }
}

/// Totals per file family, for the "by type" summary.
struct TypeTotal: Identifiable {
    let family: FileFamily
    let bytes: UInt64
    let files: Int
    var id: String { family.rawValue }
}

struct Breakdown {
    var rows: [BreakdownRow] = []
    var types: [TypeTotal] = []
    var total: UInt64 = 0
    var files: Int = 0
    var directories: Int = 0

    /// Children of `node`, largest first, plus a whole-subtree type histogram.
    static func of(_ node: FileItem, measure: SizeMeasure) -> Breakdown {
        var breakdown = Breakdown()
        breakdown.total = node.size(measure)
        breakdown.files = node.fileCount

        let children = node.children
            .map { (child: $0, bytes: $0.size(measure)) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        breakdown.directories = children.filter { $0.child.isDirectory }.count
        breakdown.rows = children.map {
            BreakdownRow(node: $0.child,
                         bytes: $0.bytes,
                         share: breakdown.total > 0 ? Double($0.bytes) / Double(breakdown.total) : 0)
        }

        // Per-type totals are maintained on the tree itself, so this is a read
        // rather than a walk of everything below `node`.
        let totals = node.totals()
        let bytes = totals.bytes(measure)
        breakdown.types = FileFamily.allCases.enumerated()
            .compactMap { slot, family in
                bytes[slot] > 0
                    ? TypeTotal(family: family, bytes: bytes[slot], files: Int(totals.counts[slot]))
                    : nil
            }
            .sorted { $0.bytes > $1.bytes }
        return breakdown
    }
}
