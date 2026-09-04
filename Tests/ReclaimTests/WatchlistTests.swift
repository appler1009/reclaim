import Foundation
import Testing
@testable import DiskMap

@MainActor
@Suite("Watchlist")
struct WatchlistTests {
    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "reclaim-watchlist-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return suite
    }

    @Test func addingAndRemovingSurvivesARoundTrip() {
        let defaults = defaults()
        let list = Watchlist(defaults: defaults)
        list.add("/Volumes/Backup Disk")
        list.add("/tmp")

        #expect(list.targets == ["/Volumes/Backup Disk", "/tmp"], "in the order they were added")
        #expect(Watchlist(defaults: defaults).targets == list.targets, "read back from defaults")

        list.remove("/tmp")
        #expect(Watchlist(defaults: defaults).targets == ["/Volumes/Backup Disk"])
    }

    @Test func aTargetIsOnlyWatchedOnce() {
        let list = Watchlist(defaults: defaults())
        list.add("/tmp")
        list.add("/tmp/")
        #expect(list.targets == ["/tmp"], "a trailing slash is the same folder")
        #expect(list.contains("/tmp/"))
    }

    @Test func togglingIsAddingOrRemoving() {
        let list = Watchlist(defaults: defaults())
        list.toggle("/tmp")
        #expect(list.contains("/tmp"))
        list.toggle("/tmp")
        #expect(!list.contains("/tmp"))
    }

    @Test func junkInDefaultsDoesNotBecomeAJunkList() {
        let defaults = defaults()
        defaults.set(["/tmp", "/tmp", "/tmp/"], forKey: Watchlist.key)
        #expect(Watchlist(defaults: defaults).targets == ["/tmp"], "duplicates collapse")
    }
}

@MainActor
@Suite("Watchlist rescan")
struct WatchlistRescanTests {
    /// A runner whose scans are recorded rather than performed, and whose work
    /// happens inline so a test can assert on it.
    private func runner(_ targets: [String],
                        scanned: @escaping (String) -> Void) -> WatchlistRescan {
        let defaults = UserDefaults(suiteName: "reclaim-runner-\(UUID().uuidString)")!
        let list = Watchlist(defaults: defaults)
        for target in targets { list.add(target) }
        return WatchlistRescan(watchlist: list,
                               schedule: NightlyRescan(defaults: defaults),
                               scan: scanned,
                               dispatch: { work in work() })
    }

    @Test func everyWatchedTargetIsScannedInTurn() {
        NightlyRescan.releaseClaims()
        var scanned: [String] = []
        let runner = runner(["/tmp/one", "/tmp/two"]) { scanned.append($0) }

        let taken = runner.runDue()
        #expect(taken == ["/tmp/one", "/tmp/two"])
        #expect(scanned == ["/tmp/one", "/tmp/two"], "one after another, in list order")
    }

    @Test func aTargetAWindowAlreadyTookIsLeftAlone() {
        NightlyRescan.releaseClaims()
        var scanned: [String] = []
        let runner = runner(["/tmp/one", "/tmp/two"]) { scanned.append($0) }
        // A window showing /tmp/one got to it first tonight.
        #expect(NightlyRescan.claim("/tmp/one"))

        #expect(runner.runDue() == ["/tmp/two"])
        #expect(scanned == ["/tmp/two"], "no target is scanned twice in one night")
    }

    @Test func anEmptyWatchlistRunsNothingAndBooksNothing() {
        NightlyRescan.releaseClaims()
        var scanned: [String] = []
        let runner = runner([]) { scanned.append($0) }
        #expect(runner.runDue().isEmpty)
        #expect(scanned.isEmpty)
        #expect(runner.scheduledFor == nil, "nothing to do, so nothing on the clock")
    }

    @Test func addingTheFirstTargetPutsTheRunOnTheClock() {
        NightlyRescan.releaseClaims()
        let defaults = UserDefaults(suiteName: "reclaim-runner-\(UUID().uuidString)")!
        defaults.set(true, forKey: NightlyRescan.enabledKey)
        let list = Watchlist(defaults: defaults)
        let runner = WatchlistRescan(watchlist: list,
                                     schedule: NightlyRescan(defaults: defaults),
                                     scan: { _ in },
                                     dispatch: { work in work() })
        #expect(runner.scheduledFor == nil)

        list.add("/tmp/one")
        runner.armFromList()
        #expect(runner.scheduledFor != nil, "the list is what arms this schedule")

        list.remove("/tmp/one")
        runner.armFromList()
        #expect(runner.scheduledFor == nil)
    }

    @Test func aTargetThatIsNotThereIsSkippedRatherThanRecorded() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-unattended-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)

        // An unmounted volume looks exactly like this.
        #expect(UnattendedScan.run(path: "/Volumes/Not Mounted \(UUID().uuidString)",
                                   store: store) == nil)
        #expect(store.targets().isEmpty, "history gains nothing from a scan that did not happen")
    }

    @Test func anUnattendedScanRecordsATargetWithItsVolumeFigures() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-unattended-\(UUID().uuidString)")
        let scanned = directory.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4_096).write(to: scanned.appendingPathComponent("a.bin"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnapshotStore(directory: directory.appendingPathComponent("history"))
        let snapshot = try #require(UnattendedScan.run(path: scanned.path, store: store))
        #expect(snapshot.fileCount == 1)
        #expect(snapshot.volume != nil, "the volume figures are the point of recording it")
        #expect(store.snapshots(forTarget: scanned.path).count == 1)
    }
}

@Suite("Settings labels")
struct SettingsLabelTests {
    private func volume(_ name: String, capacity: UInt64, path: String) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: path), name: name, capacity: capacity,
                   available: capacity / 2, free: capacity / 2,
                   isInternal: path == "/", isRemovable: false, isReadOnly: false)
    }

    @Test func aVolumeIsNamedWithItsSizeAndWhereItIsMounted() {
        // Sizes are the app's own everywhere: powers of 1024, as the map and
        // the header strip already show them.
        #expect(SettingsView.label(for: volume("Macintosh HD", capacity: 245_000_000_000, path: "/"))
                == "Macintosh HD — 228 GB · /")
    }

    @Test func twoDisksSharingANameAreStillToldApart() {
        // The case the label exists for: a clone carries the original's name.
        let original = SettingsView.label(for: volume("Untitled", capacity: 500_000_000_000,
                                                      path: "/Volumes/Untitled"))
        let clone = SettingsView.label(for: volume("Untitled", capacity: 2_000_000_000_000,
                                                   path: "/Volumes/Untitled 1"))
        #expect(original != clone)
        #expect(clone.contains("/Volumes/Untitled 1"))
        #expect(clone.contains("1.8 TB"))
    }
}
