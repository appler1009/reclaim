import Foundation
import Testing
@testable import DiskMap

/// The running totals are indexed by branch number, fixed when the scan starts.
/// The tree they are copied onto is re-ordered while the scan runs, so the two
/// must be matched by identity rather than by position.
@Suite("Live branch mapping")
@MainActor
struct LiveBranchMappingTests {
    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        // Deliberately unequal, so "largest first" is a different order from
        // whatever order the directory happens to be read in.
        for (index, branch) in ["alpha", "bravo", "charlie", "delta", "echo"].enumerated() {
            for file in 0 ..< 4 {
                try fixture.file("\(branch)/file-\(file).bin", bytes: 4_000 * (index + 1) * (file + 1))
            }
        }
        return fixture
    }

    /// Every folder must show its own size, however the children are ordered.
    @Test func sizesFollowTheFolderTheyBelongTo() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let session = ScanSession()
        var partial: FileItem?
        let finished = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                                 session: session) { partial = $0 })
        let top = try #require(partial)

        let model = AppModel()
        model.isScanning = true
        model.installPartial(top, session: session)

        // The tick above sorted the children; a later tick sees that new order.
        // Reversing here stands in for any re-ordering and keeps the test
        // independent of the order the filesystem returned.
        model.scanRoot?.children.reverse()
        model.applyBranchTotals(from: session)

        let root = try #require(model.scanRoot)
        for child in root.children where child.isDirectory {
            let real = try #require(finished.children.first { $0.name == child.name })
            #expect(child.physicalSize == real.physicalSize,
                    "\(child.name) showed \(child.physicalSize), should be \(real.physicalSize)")
        }
    }

    /// The totals are final once the scan is over, so re-applying them must not
    /// change what anything reports.
    @Test func reapplyingFinishedTotalsChangesNothing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let session = ScanSession()
        var partial: FileItem?
        _ = Scanner.scan(url: fixture.root, options: ScanOptions(), session: session) { partial = $0 }
        let top = try #require(partial)

        let model = AppModel()
        model.isScanning = true
        model.installPartial(top, session: session)
        let first = (model.scanRoot?.children ?? []).map { ($0.name, $0.physicalSize) }

        for _ in 0 ..< 3 { model.applyBranchTotals(from: session) }
        let later = (model.scanRoot?.children ?? []).map { ($0.name, $0.physicalSize) }

        #expect(first.sorted { $0.0 < $1.0 }.map(\.1) == later.sorted { $0.0 < $1.0 }.map(\.1),
                "sizes moved between folders across ticks")
    }
}
