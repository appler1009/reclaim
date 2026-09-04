import Foundation
import Testing
@testable import DiskMap

@Suite("Volume space")
struct VolumeSpaceTests {
    private func space(capacity: UInt64, available: UInt64, free: UInt64,
                       volume: String = "/") -> VolumeSpace {
        VolumeSpace(volume: volume, capacity: capacity, available: available, free: free)
    }

    @Test func occupiedSpaceCountsWhatThePurgeablePromiseHides() {
        // Finder says 17 GB free because it would purge 5 GB if pressed; only
        // 12 GB is free right now, so 88 GB of a 100 GB disk is occupied.
        let volume = space(capacity: 100, available: 17, free: 12)
        #expect(volume.used == 88, "measured from what is truly free, not the promise")
        #expect(volume.purgeable == 5)
    }

    @Test func aVolumeThatIsNotHoldingAnythingBackHasNoPurgeableSpace() {
        #expect(space(capacity: 100, available: 12, free: 12).purgeable == 0)
        // Nonsense figures must not underflow into an enormous number.
        #expect(space(capacity: 100, available: 10, free: 12).purgeable == 0)
        #expect(space(capacity: 10, available: 20, free: 20).used == 0)
    }

    @Test func onlyAScanOfTheWholeVolumeCoversIt() {
        let root = space(capacity: 100, available: 20, free: 20)
        #expect(root.covers(target: "/"))
        #expect(!root.covers(target: "/Users/someone"))

        let external = space(capacity: 100, available: 20, free: 20, volume: "/Volumes/500GB SSD")
        #expect(external.covers(target: "/Volumes/500GB SSD"))
        #expect(external.covers(target: "/Volumes/500GB SSD/"), "a trailing slash is the same volume")
        #expect(!external.covers(target: "/Volumes/500GB SSD/Omarchy"))
    }

    @Test func aSnapshotWrittenBeforeVolumeFiguresExistedStillDecodes() throws {
        // The shape history was stored in before this feature: no `volume` key.
        let json = """
            [{"id":"\(UUID().uuidString)","target":"/tmp/old","takenAt":"2026-01-01T00:00:00Z",
              "totalBytes":1000,"fileCount":1,"unreadableCount":0,
              "entries":[{"path":"/tmp/old/a.bin","bytes":1000,"isDirectory":false}]}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let history = try decoder.decode([Snapshot].self, from: Data(json.utf8))
        #expect(history.first?.volume == nil)
        #expect(history.first?.totalBytes == 1_000)
    }
}

@Suite("Local snapshots")
struct LocalSnapshotTests {
    @Test func tmutilOutputIsReadAsSnapshotsWithDates() throws {
        let output = """
            Snapshots for disk /:
            com.apple.TimeMachine.2026-09-03-152436.local
            com.apple.TimeMachine.2026-09-03-160715.local
            """
        let entries = LocalSnapshots.parse(output)
        #expect(entries.count == 2, "the heading line is not a snapshot")
        #expect(entries.first?.name == "com.apple.TimeMachine.2026-09-03-152436.local")

        let taken = try #require(entries.first?.takenAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                    from: taken)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 3)
        #expect(parts.hour == 15 && parts.minute == 24)
        #expect(entries.map(\.takenAt) == entries.map(\.takenAt).sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) },
                "oldest first")
    }

    @Test func aVolumeWithNoSnapshotsReportsNone() {
        #expect(LocalSnapshots.parse("Snapshots for disk /Volumes/Data:").isEmpty)
        #expect(LocalSnapshots.list(volume: "/", run: { _ in nil }).isEmpty,
                "tmutil failing is not an error, just no answer")
    }
}

@Suite("Space report")
struct SpaceReportTests {
    private let target = "/"
    private let quietProbe = SpaceProbe(localSnapshots: { _ in [] }, trashBytes: { _ in nil })

    private func store() -> (SnapshotStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-space-\(UUID().uuidString)")
        return (SnapshotStore(directory: directory), directory)
    }

    /// A scan of `target` totalling `scanned`, on a volume with `free` free.
    private func snapshot(target: String, scanned: UInt64, capacity: UInt64,
                          available: UInt64, free: UInt64, at date: Date,
                          volume: String = "/") -> Snapshot {
        let file = FileItem(name: "big.bin", isDirectory: false,
                            logicalSize: scanned, physicalSize: scanned)
        let root = FileItem(name: target, isDirectory: true, fileCount: 1, children: [file])
        root.physicalSize = scanned
        return Snapshot(root: root, target: target, measure: .physical,
                        volume: VolumeSpace(volume: volume, capacity: capacity,
                                            available: available, free: free),
                        takenAt: date)
    }

    @Test func spaceThatWentNowhereTheScanCanSeeIsReportedAsUnaccounted() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = Date().addingTimeInterval(-86_400)

        // The disk loses 14 GB while the scanned tree grows by 1.
        store.record(snapshot(target: target, scanned: 200, capacity: 245,
                              available: 31, free: 31, at: earlier))
        store.record(snapshot(target: target, scanned: 201, capacity: 245,
                              available: 17, free: 17, at: Date()))

        let report = try #require(DiskQueries(store: store).space(target: target, probe: quietProbe))
        #expect(report.coversWholeVolume)
        #expect(report.points.count == 2)
        #expect(report.latest.unaccounted == 27, "228 occupied, 201 of it in files")

        let change = try #require(report.change)
        #expect(change.available == -14, "free space fell by 14")
        #expect(change.scanned == 1, "and the tree barely moved")
        #expect(change.unaccounted == 13, "which is where the rest of it went")
        #expect(change.availableHuman.hasPrefix("−"))
        #expect(change.scannedHuman.hasPrefix("+"))
    }

    @Test func theBaselineCanBePickedByDate() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()

        for (daysAgo, available) in [(3, 40), (2, 31), (1, 20), (0, 17)] {
            store.record(snapshot(target: target, scanned: 200, capacity: 245,
                                  available: UInt64(available), free: UInt64(available),
                                  at: now.addingTimeInterval(Double(-86_400 * daysAgo))))
        }

        let queries = DiskQueries(store: store)
        let wholeWindow = try #require(queries.space(target: target, probe: quietProbe))
        #expect(wholeWindow.change?.available == -23, "oldest on record by default")

        let recent = try #require(queries.space(target: target,
                                                since: now.addingTimeInterval(-86_400 * 1.5),
                                                probe: quietProbe))
        #expect(recent.change?.available == -14, "the last scan at or before the cutoff")
    }

    @Test func aScanOfAFolderCannotBeSubtractedFromItsVolume() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.record(snapshot(target: "/Users/someone", scanned: 94, capacity: 245,
                              available: 17, free: 17, at: Date()))

        let report = try #require(DiskQueries(store: store)
            .space(target: "/Users/someone", probe: quietProbe))
        #expect(!report.coversWholeVolume)
        #expect(report.latest.unaccounted == nil, "the two totals describe different things")
        #expect(report.latest.available == 17, "the volume's own figures still stand")
        #expect(report.summary.contains("not the whole volume"))
    }

    @Test func theSummaryNamesTheThingsSpaceHidesIn() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 17 GB free by Finder's account, 12 truly free: 5 GB purgeable.
        store.record(snapshot(target: target, scanned: 200, capacity: 245,
                              available: 17, free: 12, at: Date()))
        let probe = SpaceProbe(
            localSnapshots: { _ in
                [LocalSnapshots.Entry(name: "com.apple.TimeMachine.2026-09-03-152436.local",
                                      takenAt: Date())]
            },
            trashBytes: { _ in 3 })

        let report = try #require(DiskQueries(store: store).space(target: target, probe: probe))
        #expect(report.latest.purgeable == 5)
        #expect(report.summary.contains("purgeable"))
        #expect(report.summary.contains("1 local Time Machine snapshot"))
        #expect(report.summary.contains("Trash"))
        #expect(report.trashBytes == 3)
    }

    @Test func aTargetWithoutRecordedVolumeFiguresHasNoReport() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = FileItem(name: "/tmp/plain", isDirectory: true)
        root.physicalSize = 10
        store.record(Snapshot(root: root, target: "/tmp/plain", measure: .physical))

        #expect(DiskQueries(store: store).space(target: "/tmp/plain", probe: quietProbe) == nil,
                "nothing to say, rather than a report full of zeroes")
    }

    @Test func onlyScansCarryingVolumeFiguresArePlotted() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = Date().addingTimeInterval(-86_400)

        let bare = FileItem(name: target, isDirectory: true)
        bare.physicalSize = 190
        store.record(Snapshot(root: bare, target: target, measure: .physical, takenAt: earlier))
        store.record(snapshot(target: target, scanned: 201, capacity: 245,
                              available: 17, free: 17, at: Date()))

        let report = try #require(DiskQueries(store: store).space(target: target, probe: quietProbe))
        #expect(report.points.count == 1, "the older scan has no figures to plot")
        #expect(report.change == nil, "and nothing to compare against")
    }
}

@Suite("Space over MCP")
struct SpaceToolTests {
    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-space-mcp-\(UUID().uuidString)")
    }

    private func call(_ endpoint: MCPEndpoint, target: String) throws -> [String: Any] {
        try #require(endpoint.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": "volume_space",
                                                 "arguments": ["target": target]]]))
    }

    @Test func anAgentGetsTheVolumeFiguresAsJSON() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)

        let root = FileItem(name: "/", isDirectory: true, fileCount: 1,
                            children: [FileItem(name: "big.bin", isDirectory: false,
                                                logicalSize: 201, physicalSize: 201)])
        root.physicalSize = 201
        store.record(Snapshot(root: root, target: "/", measure: .physical,
                              volume: VolumeSpace(volume: "/", capacity: 245,
                                                  available: 17, free: 17)))

        let response = try call(MCPEndpoint(queries: DiskQueries(store: store),
                                            scanner: { _ in nil }), target: "/")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] == nil)
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("\"unaccounted\""))
        #expect(text.contains("\"coversWholeVolume\""))
    }

    @Test func aTargetScannedBeforeFiguresWereKeptSaysSoUsefully() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let root = FileItem(name: "/tmp/old", isDirectory: true)
        root.physicalSize = 10
        store.record(Snapshot(root: root, target: "/tmp/old", measure: .physical))

        let response = try call(MCPEndpoint(queries: DiskQueries(store: store),
                                            scanner: { _ in nil }), target: "/tmp/old")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        // The fix is to scan again, and the message has to say that.
        #expect(text.contains("scan it again"))
    }
}
