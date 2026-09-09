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

    private func watcher(_ scheduler: Scheduler,
                         changed: @escaping () -> Void) -> TrashWatcher {
        TrashWatcher(onChange: changed, schedule: { scheduler.take($0, $1) })
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

    @Test func aWatcherWithNothingToWatchSaysNothing() {
        let scheduler = Scheduler()
        var changes = 0
        let watcher = watcher(scheduler) { changes += 1 }

        // No Trash directory exists for this, which is a state to be in rather
        // than an error: nothing is watched, so nothing is reported.
        watcher.watch(volumeContaining: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        scheduler.fire()
        #expect(changes == 0)
    }
}
