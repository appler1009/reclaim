import Foundation
import Testing
@testable import DiskMap

@Suite("One scan at a time", .serialized)
struct ScanGateTests {
    @Test func anUnattendedScanWaitsItsTurn() {
        let first = ScanGate.shared.acquire(unattended: true) {}
        defer { first.release() }
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let second = ScanGate.shared.acquire(unattended: true) {}
            entered.signal()
            second.release()
        }
        #expect(entered.wait(timeout: .now() + 0.2) == .timedOut)
        first.release()
        #expect(entered.wait(timeout: .now() + 2) == .success)
    }

    @Test func aUserScanCancelsTheUnattendedOne() {
        let session = ScanSession()
        let first = ScanGate.shared.acquire(unattended: true) { session.cancel() }
        defer { first.release() }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let second = ScanGate.shared.acquire(unattended: false) {}
            second.release()
            done.signal()
        }
        for _ in 0 ..< 50 where !session.isCancelled {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(session.isCancelled)
        first.release()
        #expect(done.wait(timeout: .now() + 2) == .success)
    }
}

@Suite("Summary scans")
struct SummaryScanTests {
    @Test func aSummaryMatchesAFullScanOfTheSameTree() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("a.bin", bytes: 12_000)
        try fixture.file("nested/b.bin", bytes: 40_000)
        try fixture.file("nested/deep/c.bin", bytes: 1_000)

        let root = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                             session: ScanSession()))
        let summary = try #require(Scanner.summarize(url: fixture.root, options: ScanOptions(),
                                                     session: ScanSession()))
        #expect(summary.physicalSize == root.physicalSize)
        #expect(summary.logicalSize == root.logicalSize)
        #expect(summary.fileCount == root.fileCount)
        #expect(summary.topLevelCount == root.children.count)

        let fromTree = Snapshot(root: root, target: fixture.root.path, measure: .physical)
        let fromSummary = Snapshot(draft: Snapshot.Draft(target: fixture.root.path,
                                                         totalBytes: summary.physicalSize,
                                                         fileCount: summary.fileCount,
                                                         unreadableCount: summary.unreadableCount,
                                                         collected: summary.entries),
                                   measure: .physical)
        #expect(Set(fromSummary.entries.map(\.path)) == Set(fromTree.entries.map(\.path)))
    }

    @Test func anUnattendedScanIsSkippedUnderMemoryPressure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("a.bin", bytes: 100)
        let directory = fixture.root.appendingPathComponent("history")
        defer { MemoryPressure.setOverrideForTesting(nil) }
        MemoryPressure.setOverrideForTesting(true)
        let store = SnapshotStore(directory: directory)
        #expect(UnattendedScan.run(path: fixture.root.path, store: store) == nil)
        #expect(store.targets().isEmpty)
    }
}

@Suite("Folding")
struct FoldingTests {
    @Test func nodeModulesIsOneEntryAndStillCounts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("node_modules/pkg/index.js", bytes: 8_000)
        try fixture.file("keep.bin", bytes: 80_000)

        var options = ScanOptions()
        options.foldNames = ["node_modules"]
        let folded = try #require(Scanner.scan(url: fixture.root, options: options, session: ScanSession()))
        let full = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(), session: ScanSession()))

        let modules = try #require(folded.children.first { $0.name == "node_modules" })
        #expect(modules.isFolded)
        #expect(modules.children.isEmpty)
        #expect(folded.physicalSize == full.physicalSize)
        #expect(folded.fileCount == full.fileCount)
    }

    @Test func smallFilesBecomeOneEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("tiny-a.bin", bytes: 100)
        try fixture.file("tiny-b.bin", bytes: 200)
        try fixture.file("large.bin", bytes: 80_000)

        var options = ScanOptions()
        options.smallFileLimit = 64 * 1024
        let root = try #require(Scanner.scan(url: fixture.root, options: options, session: ScanSession()))
        #expect(root.children.contains { $0.name == "large.bin" })
        let bundle = try #require(root.children.first { $0.representsSmallFiles })
        #expect(bundle.fileCount == 2)
        #expect(bundle.name == "2 small files")
        let full = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(), session: ScanSession()))
        #expect(root.physicalSize == full.physicalSize)
    }
}

@Suite("Paths that are not scanned")
struct ScanPathTests {
    @Test func aNetworkVolumeIsRefused() {
        let url = URL(fileURLWithPath: "/Volumes/Share")
        let refusal = ScanPaths.refusal(of: url) { _ in false }
        #expect(refusal?.code == "network")
    }

    @Test func aTimeMachinePathIsRefused() {
        let url = URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac")
        #expect(ScanPaths.refusal(of: url, volumeIsLocal: { _ in true })?.code == "timeMachine")
        let snapshots = URL(fileURLWithPath: "/.MobileBackups")
        #expect(ScanPaths.refusal(of: snapshots, volumeIsLocal: { _ in true })?.code == "timeMachine")
    }

    @Test func aLocalDiskIsAccepted() {
        #expect(ScanPaths.refusal(of: URL(fileURLWithPath: "/Users"), volumeIsLocal: { _ in true }) == nil)
    }

    @Test func aDescendantSitsInsideItsAncestor() {
        #expect(TargetPath.contains(ancestor: "/", descendant: "/System"))
        #expect(TargetPath.isStrictDescendant("/System", of: "/"))
        #expect(!TargetPath.isStrictDescendant("/", of: "/"))
        #expect(TargetPath.contains(ancestor: "/Users/me", descendant: "/Users/me/works"))
        #expect(!TargetPath.contains(ancestor: "/Users/me", descendant: "/Users/media"))
    }
}

@Suite("Tonight's tree")
struct NightWindowTests {
    @Test func theNightStartsAtTheConfiguredHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27,
                                                         hour: 3, minute: 2))!
        let began = NightlyRescan.nightBegan(before: morning, hour: 3, calendar: calendar)
        #expect(began == calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 3)))

        let before = morning.addingTimeInterval(-180)
        let previous = NightlyRescan.nightBegan(before: before, hour: 3, calendar: calendar)
        #expect(previous == calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 3)))
    }
}

@Suite("History stays out of the real folder")
struct HistoryIsolationTests {
    @Test func theDefaultStoreInATestIsTemporary() {
        #expect(SnapshotStore.defaultDirectory.path.contains("reclaim-test-history"))
    }
}
