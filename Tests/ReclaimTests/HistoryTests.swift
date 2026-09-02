import Foundation
import Testing
@testable import DiskMap

@Suite("Scan history")
struct SnapshotTests {
    private func tree() -> FileItem {
        func file(_ name: String, _ bytes: UInt64) -> FileItem {
            FileItem(name: name, isDirectory: false, logicalSize: bytes, physicalSize: bytes)
        }
        let deep = FileItem(name: "deep", isDirectory: true, children: [file("d.bin", 3_000)])
        deep.physicalSize = 3_000
        let nested = FileItem(name: "nested", isDirectory: true, children: [deep, file("n.bin", 2_000)])
        nested.physicalSize = 5_000
        let root = FileItem(name: "/tmp/history", isDirectory: true, fileCount: 3,
                            children: [nested, file("top.bin", 4_000)])
        root.physicalSize = 9_000
        return root
    }

    @Test func aSnapshotKeepsTheShapeOfTheTree() {
        let snapshot = Snapshot(root: tree(), target: "/tmp/history", measure: .physical)
        #expect(snapshot.totalBytes == 9_000)
        let paths = snapshot.entries.map(\.path)
        #expect(paths.contains("/tmp/history/nested"))
        #expect(paths.contains("/tmp/history/nested/deep"))
        #expect(paths.contains("/tmp/history/top.bin"))
    }

    @Test func sizesCanBeLookedUpByPath() {
        let snapshot = Snapshot(root: tree(), target: "/tmp/history", measure: .physical)
        #expect(snapshot.bytes(forPath: "/tmp/history") == 9_000, "the target itself")
        #expect(snapshot.bytes(forPath: "/tmp/history/nested") == 5_000)
        #expect(snapshot.bytes(forPath: "/tmp/history/gone") == nil)
    }

    @Test func aHugeTreeStaysASmallSnapshot() {
        // A directory of ten thousand small files must not become a huge record.
        let children = (0 ..< 10_000).map { index -> FileItem in
            let size = UInt64(1_000)
            return FileItem(name: "file-\(index).bin", isDirectory: false,
                            logicalSize: size, physicalSize: size)
        }
        let root = FileItem(name: "/tmp/wide", isDirectory: true, children: children)
        root.physicalSize = 10_000_000

        let snapshot = Snapshot(root: root, target: "/tmp/wide", measure: .physical)
        #expect(snapshot.entries.count <= Snapshot.maximumEntries)
        #expect(snapshot.totalBytes == 10_000_000, "the total is exact even when entries are capped")
    }
}

@Suite("Snapshot store")
struct SnapshotStoreTests {
    private func makeStore() throws -> (SnapshotStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-history-\(UUID().uuidString)")
        return (SnapshotStore(directory: directory), directory)
    }

    private func snapshot(target: String, bytes: UInt64, at date: Date) -> Snapshot {
        let root = FileItem(name: target, isDirectory: true,
                            children: [FileItem(name: "a.bin", isDirectory: false,
                                                logicalSize: bytes, physicalSize: bytes)])
        root.physicalSize = bytes
        return Snapshot(root: root, target: target, measure: .physical, takenAt: date)
    }

    @Test func historySurvivesARoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()

        store.record(snapshot(target: "/tmp/one", bytes: 1_000, at: now.addingTimeInterval(-3600)))
        store.record(snapshot(target: "/tmp/one", bytes: 2_000, at: now))

        let history = store.snapshots(forTarget: "/tmp/one")
        #expect(history.count == 2)
        #expect(history.first?.totalBytes == 2_000, "newest first")
        #expect(history.last?.totalBytes == 1_000)
    }

    @Test func onlyTheRecentPastIsKept() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()

        for index in 0 ..< (SnapshotStore.keepPerTarget + 8) {
            store.record(snapshot(target: "/tmp/many", bytes: UInt64(index + 1) * 1_000,
                                  at: now.addingTimeInterval(Double(index))))
        }
        let history = store.snapshots(forTarget: "/tmp/many")
        #expect(history.count == SnapshotStore.keepPerTarget)
        // What is dropped is the oldest, not the newest.
        #expect(history.first?.totalBytes == UInt64(SnapshotStore.keepPerTarget + 8) * 1_000)
    }

    @Test func targetsAreKeptApart() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.record(snapshot(target: "/tmp/alpha", bytes: 1_000, at: Date()))
        store.record(snapshot(target: "/Volumes/Backup Disk", bytes: 2_000, at: Date()))

        #expect(store.snapshots(forTarget: "/tmp/alpha").count == 1)
        #expect(store.snapshots(forTarget: "/Volumes/Backup Disk").count == 1)
        #expect(Set(store.targets()) == ["/tmp/alpha", "/Volumes/Backup Disk"])
    }

    @Test func comparingAgainstThePreviousScanReportsTheChange() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = Date().addingTimeInterval(-86_400)

        store.record(snapshot(target: "/tmp/grow", bytes: 1_000, at: earlier))
        let previous = try #require(store.mostRecent(forTarget: "/tmp/grow"))

        let change = SizeChange(bytes: Int64(3_000) - Int64(previous.totalBytes), since: previous.takenAt)
        #expect(change.isGrowth)
        #expect(change.magnitude == 2_000)
        #expect(change.label(minimum: 1) == "+2.0 KB")
        #expect(change.label(minimum: 1024 * 1024) == nil, "small moves are not worth reporting")
    }

    @Test func anUnknownTargetHasNoHistoryRatherThanFailing() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.snapshots(forTarget: "/never/scanned").isEmpty)
        #expect(store.mostRecent(forTarget: "/never/scanned") == nil)
    }
}
