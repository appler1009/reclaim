import Foundation
import Testing
@testable import DiskMap

@MainActor
@Suite("Trash watcher")
struct TrashWatcherTests {
    /// Holds what was scheduled instead of scheduling it, so the debounce is
    /// driven by the test rather than by the clock.
    private final class Scheduler {
        private(set) var pending: [() -> Void] = []
        private(set) var delays: [TimeInterval] = []

        func take(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            delays.append(delay)
            pending.append(work)
        }

        /// Runs everything that was waiting, oldest first, as the run loop would.
        func fire() {
            let due = pending
            pending.removeAll()
            for work in due { work() }
        }
    }

    /// Watches only what the test says, so nothing here opens a watch on the
    /// machine's own Trash: a path that does not exist still resolves to a
    /// volume, and that volume's Trash is real and in use.
    private func watcher(_ scheduler: Scheduler,
                         watching: @escaping () -> [URL] = { [] },
                         changed: @escaping () -> Void = {}) -> TrashWatcher {
        TrashWatcher(onChange: changed,
                     schedule: { scheduler.take($0, $1) },
                     trashURLs: { _ in watching() })
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aChangeIsReportedOnceItHasSettled() {
        let scheduler = Scheduler()
        var changes = 0
        let watcher = watcher(scheduler) { changes += 1 }

        watcher.noteChange()
        #expect(changes == 0, "not until it has settled")
        #expect(scheduler.delays == [TrashWatcher.settle])

        scheduler.fire()
        #expect(changes == 1)
    }

    @Test func emptyingTheTrashIsOneChange() {
        // Hundreds of removals, one event each. Measuring on the first would
        // count a Trash still emptying; measuring on all of them would walk the
        // directory once per file deleted.
        let scheduler = Scheduler()
        var changes = 0
        let watcher = watcher(scheduler) { changes += 1 }

        for _ in 0 ..< 200 { watcher.noteChange() }
        scheduler.fire()

        #expect(changes == 1, "the last note is the only one that survives")
    }

    @Test func theTrashCanChangeAgainAfterwards() {
        let scheduler = Scheduler()
        var changes = 0
        let watcher = watcher(scheduler) { changes += 1 }

        watcher.noteChange()
        scheduler.fire()
        // Something else is thrown away later in the session.
        watcher.noteChange()
        scheduler.fire()

        #expect(changes == 2, "the debounce is per burst, not once for the run")
    }

    @Test func aVolumeWithNoTrashYetIsWatchedByNothing() {
        let scheduler = Scheduler()
        var changes = 0
        let watcher = watcher(scheduler, changed: { changes += 1 })

        // A volume whose Trash does not exist yet is a state to be in, not an
        // error: there is nothing to open, so nothing is watched or reported.
        watcher.watch(volumeContaining: URL(fileURLWithPath: "/tmp"))
        #expect(!watcher.isWatching)
        scheduler.fire()
        #expect(changes == 0)
    }

    @Test func theWatchIsTakenUpOnceThereIsSomethingToWatch() throws {
        let scheduler = Scheduler()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Nothing to watch at first — the Trash is made later, which is what
        // happens when this app puts the first item in an empty volume's.
        var trash: [URL] = []
        let watcher = watcher(scheduler, watching: { trash })

        watcher.watch(volumeContaining: directory)
        #expect(!watcher.isWatching)

        trash = [directory]
        watcher.rearmIfIdle()
        #expect(watcher.isWatching, "a measurement is when it looks again")
    }

    @Test func aWatchThatIsAlreadyRunningIsLeftAlone() throws {
        let scheduler = Scheduler()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = watcher(scheduler, watching: { [directory] })

        watcher.watch(volumeContaining: directory)
        #expect(watcher.isWatching)
        // Called after every measurement, so it must be cheap and idempotent
        // rather than tearing down a working watch and building it again.
        watcher.rearmIfIdle()
        #expect(watcher.isWatching)
    }

    @Test func aDescriptorThatHasGoneStaleIsReplaced() throws {
        let scheduler = Scheduler()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes = 0
        let watcher = watcher(scheduler, watching: { [directory] }, changed: { changes += 1 })

        watcher.watch(volumeContaining: directory)
        // The Trash folder itself replaced: the descriptor reports this once
        // and then reports nothing ever again, so it is dropped here.
        watcher.noteChange(descriptorIsStale: true)
        #expect(!watcher.isWatching, "the dead descriptor is let go at once")

        scheduler.fire()
        #expect(changes == 1)
        #expect(watcher.isWatching, "and a new one is opened on the way out")
    }
}
