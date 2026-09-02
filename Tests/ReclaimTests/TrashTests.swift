import Foundation
import Testing
@testable import DiskMap

@Suite("Trashing")
@MainActor
struct TrashTests {
    /// Builds a scanned model over a real temp tree, with the trash operation
    /// replaced so tests never put anything in the user's actual Trash.
    private func model(_ fixture: Fixture) throws -> AppModel {
        let model = AppModel()
        var removed: [URL] = []
        model.trashItem = { url in removed.append(url) }
        let root = try #require(Scanner.scan(url: fixture.root,
                                             options: ScanOptions(),
                                             session: ScanSession()))
        model.adoptForTesting(root: root, url: fixture.root)
        return model
    }

    @Test func trashingUpdatesSizesAndTellsTheMapToRedraw() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("keep.bin", bytes: 8_000)
        try fixture.file("junk/big.bin", bytes: 40_000)

        let model = try model(fixture)
        let before = model.viewedBytes
        let revisionBefore = model.treeRevision
        let junk = try #require(model.breakdown.rows.first { $0.name == "junk" }).node

        model.toggleStaged(junk)
        let report = await model.trashStaged()

        #expect(report.trashed.count == 1)
        #expect(model.viewedBytes < before)
        #expect(model.scanRoot?.children.contains { $0 === junk } == false)
        // The folder in view keeps its identity, so only this tells the map.
        #expect(model.treeRevision == revisionBefore + 1)
        #expect(model.breakdown.rows.contains { $0.name == "junk" } == false)
        #expect(model.staged.isEmpty)
    }

    @Test func failuresAreReportedAndTheItemStays() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("stubborn.bin", bytes: 4_000)

        let model = AppModel()
        model.trashItem = { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        let root = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                             session: ScanSession()))
        model.adoptForTesting(root: root, url: fixture.root)
        let item = try #require(model.breakdown.rows.first).node
        let sizeBefore = model.viewedBytes

        model.toggleStaged(item)
        let report = await model.trashStaged()

        #expect(report.trashed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(model.viewedBytes == sizeBefore, "a failed delete must not shrink the total")
    }

    @Test func deletingTheFolderInViewFallsBackToTheScanRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("branch/leaf.bin", bytes: 6_000)

        let model = try model(fixture)
        let branch = try #require(model.breakdown.rows.first { $0.name == "branch" }).node
        model.zoom(into: branch)
        #expect(model.zoomRoot === branch)

        model.toggleStaged(branch)
        _ = await model.trashStaged()
        #expect(model.zoomRoot === model.scanRoot, "the view must not be left on a deleted folder")
    }

    @Test func totalsTickUpAsEachItemMoves() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for index in 0 ..< 4 {
            try fixture.file("item-\(index).bin", bytes: 20_000 - index * 1_000)
        }

        let model = AppModel()
        let root = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                             session: ScanSession()))
        model.adoptForTesting(root: root, url: fixture.root)

        // Observe the running totals from inside the trash operation itself.
        var trashBytesSeen: [UInt64] = []
        var stagedCountsSeen: [Int] = []
        model.trashItem = { _ in
            trashBytesSeen.append(model.trash.bytes)
            stagedCountsSeen.append(model.staged.count)
        }

        model.breakdown.rows.forEach { model.toggleStaged($0.node) }
        #expect(model.staged.count == 4)
        _ = await model.trashStaged()

        // Each call saw the totals from the items already moved, so they were
        // published as the run progressed rather than all at the end.
        #expect(trashBytesSeen.count == 4)
        #expect(trashBytesSeen == trashBytesSeen.sorted())
        #expect(trashBytesSeen.first == 0)
        #expect(trashBytesSeen.last ?? 0 > 0)
        #expect(stagedCountsSeen == [4, 3, 2, 1], "the selection should shrink as items go")
        #expect(model.trash.items == 4)
    }

    @Test func selectingAFolderSupersedesItsContents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("bundle/inner.bin", bytes: 5_000)

        let model = try model(fixture)
        let bundle = try #require(model.breakdown.rows.first { $0.name == "bundle" }).node
        let inner = try #require(bundle.children.first)

        model.toggleStaged(inner)
        model.toggleStaged(bundle)
        // Selecting the parent replaces the child; the child alone is redundant.
        #expect(model.staged.count == 1)
        #expect(model.staged.first === bundle)

        model.toggleStaged(inner)   // already covered by its parent
        #expect(model.staged.count == 1)
    }

}

@Suite("Rescan")
@MainActor
struct RescanTests {
    @Test func rescanReturnsToTheFolderYouWereLookingAt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("outer/inner/file.bin", bytes: 9_000)

        let model = AppModel()
        model.scan(fixture.root)
        try await waitUntilReady(model)

        let outer = try #require(model.scanRoot?.children.first { $0.name == "outer" })
        model.zoom(into: outer)
        let inner = try #require(model.zoomRoot?.children.first { $0.name == "inner" })
        model.zoom(into: inner)
        #expect(model.zoomRoot?.name == "inner")

        // Rescanning re-reads the whole target, but should not throw away where
        // the user was standing.
        model.rescan()
        try await waitUntilReady(model)
        #expect(model.zoomRoot?.name == "inner")
        #expect(model.zoomRoot !== inner, "the tree should have been rebuilt")
    }

    @Test func rescanAfterTheFolderIsGoneLandsOnWhatSurvives() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("outer/inner/file.bin", bytes: 9_000)

        let model = AppModel()
        model.scan(fixture.root)
        try await waitUntilReady(model)
        let outer = try #require(model.scanRoot?.children.first { $0.name == "outer" })
        model.zoom(into: outer)
        let inner = try #require(model.zoomRoot?.children.first { $0.name == "inner" })
        model.zoom(into: inner)

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("outer/inner"))
        model.rescan()
        try await waitUntilReady(model)
        #expect(model.zoomRoot?.name == "outer", "should stop at the deepest folder that still exists")
    }

    private func waitUntilReady(_ model: AppModel) async throws {
        for _ in 0 ..< 200 {
            if model.phase == .ready { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("scan did not finish")
    }
}
