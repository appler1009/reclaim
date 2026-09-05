import Foundation
import Testing
@testable import DiskMap

private func isolatedStore() -> (SessionStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: "reclaim.session.\(UUID().uuidString)")!
    return (SessionStore(defaults: defaults), defaults)
}

@Suite("Session state")
struct SessionStateTests {
    @Test func windowsThatShareATabGroupBecomeOneWindow() {
        let state = SessionState.of([
            SessionState.OpenTab(group: 0, target: "/"),
            SessionState.OpenTab(group: 0, target: "/tmp"),
            SessionState.OpenTab(group: 1, target: "/Users"),
        ])
        #expect(state.windows.count == 2)
        #expect(state.windows[0].targets == ["/", "/tmp"])
        #expect(state.windows[1].targets == ["/Users"])
    }

    /// A window standing on its own is not a tab group of one that everything
    /// else can join — restoring those into a single window would gather up
    /// windows somebody deliberately kept apart.
    @Test func untabbedWindowsStayApart() {
        let state = SessionState.of([
            SessionState.OpenTab(group: nil, target: "/tmp/a"),
            SessionState.OpenTab(group: nil, target: "/tmp/b"),
        ])
        #expect(state.windows.count == 2)
        #expect(state.targets == ["/tmp/a", "/tmp/b"])
    }

    @Test func tabOrderIsKept() {
        let state = SessionState.of([
            SessionState.OpenTab(group: 7, target: "/tmp/one"),
            SessionState.OpenTab(group: 7, target: "/tmp/two"),
            SessionState.OpenTab(group: 7, target: "/tmp/three"),
        ])
        #expect(state.windows[0].targets == ["/tmp/one", "/tmp/two", "/tmp/three"])
    }

    @Test func targetsAreNormalisedOnTheWayIn() {
        // The same spelling the watchlist and the snapshots use, so a restored
        // tab claims the target its own history is filed under.
        let state = SessionState.of([SessionState.OpenTab(group: nil, target: "/tmp/")])
        #expect(state.targets == [TargetPath.normalise("/tmp")])
    }

    @Test func nothingOpenIsNothingToRestore() {
        #expect(SessionState.of([]).isEmpty)
        #expect(SessionState().targets.isEmpty)
    }

    @Test func aSessionSurvivesBeingWrittenAndReadBack() {
        let (store, _) = isolatedStore()
        let state = SessionState.of([
            SessionState.OpenTab(group: 0, target: "/"),
            SessionState.OpenTab(group: 0, target: "/tmp"),
        ])
        store.save(state)
        #expect(store.load() == state)
    }

    /// An unplugged disk or a deleted folder is not reopened into a failed scan.
    @Test func targetsThatHaveGoneAreDropped() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let (store, _) = isolatedStore()
        store.save(SessionState(windows: [
            SessionState.Window(targets: [fixture.root.path, "/nowhere/at/all"]),
            SessionState.Window(targets: ["/also/gone"]),
        ]))

        let loaded = store.load()
        #expect(loaded.windows.count == 1)
        #expect(loaded.targets == [fixture.root.path])
    }

    @Test func nothingWrittenYetIsAnEmptySession() {
        let (store, _) = isolatedStore()
        #expect(store.load().isEmpty)
    }

    @Test func rubbishInDefaultsIsAnEmptySessionRatherThanACrash() {
        let (store, defaults) = isolatedStore()
        defaults.set(Data("not json".utf8), forKey: SessionStore.key)
        #expect(store.load().isEmpty)
    }
}

@Suite("Session restore")
@MainActor
struct SessionRestoreTests {
    private func restore(_ state: SessionState) -> SessionRestore {
        let (store, _) = isolatedStore()
        store.save(state)
        let restore = SessionRestore(store: store)
        restore.loadPlan()
        return restore
    }

    @Test func targetsAreHandedOutInTheOrderWindowsAreMade() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.directory("one")
        try fixture.directory("two")
        let first = fixture.root.appendingPathComponent("one").path
        let second = fixture.root.appendingPathComponent("two").path

        let restore = self.restore(SessionState(windows: [
            SessionState.Window(targets: [first, second]),
        ]))

        #expect(restore.isRestoring)
        #expect(restore.claimTarget()?.path == first)
        #expect(restore.claimTarget()?.path == second)
        // Nothing more is owed: the next window is an ordinary new one.
        #expect(restore.claimTarget() == nil)
    }

    @Test func withNothingSavedNoWindowIsClaimed() {
        let restore = self.restore(SessionState())
        #expect(!restore.isRestoring)
        #expect(restore.claimTarget() == nil)
    }

    /// The first tab of the first window is the window the app opens by itself,
    /// so it is not asked for again — everything after it is.
    @Test func onlyTheWindowsBeyondTheFirstAreOpened() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for name in ["a", "b", "c"] { try fixture.directory(name) }
        func path(_ name: String) -> String {
            fixture.root.appendingPathComponent(name).path
        }

        let restore = self.restore(SessionState(windows: [
            SessionState.Window(targets: [path("a"), path("b")]),
            SessionState.Window(targets: [path("c")]),
        ]))

        var steps: [String] = []
        var finished = false
        restore.openWindows(openWindow: { done in steps.append("window"); done() },
                            openTab: { done in steps.append("tab"); done() },
                            whenDone: { finished = true })

        #expect(steps == ["tab", "window"])
        #expect(finished)
    }

    @Test func aSingleRestoredTabAsksForNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let restore = self.restore(SessionState(windows: [
            SessionState.Window(targets: [fixture.root.path]),
        ]))

        var steps = 0
        var finished = false
        restore.openWindows(openWindow: { done in steps += 1; done() },
                            openTab: { done in steps += 1; done() },
                            whenDone: { finished = true })
        #expect(steps == 0)
        #expect(finished)
    }

    @Test func eachWindowIsOpenedOnlyAfterTheLastOneArrived() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for name in ["a", "b", "c"] { try fixture.directory(name) }
        func path(_ name: String) -> String {
            fixture.root.appendingPathComponent(name).path
        }

        let restore = self.restore(SessionState(windows: [
            SessionState.Window(targets: [path("a"), path("b"), path("c")]),
        ]))

        // Windows are made one at a time because that is what makes claiming a
        // target first-come-first-served correct. Held here, nothing else runs.
        var release: (() -> Void)?
        var opened = 0
        restore.openWindows(openWindow: { _ in },
                            openTab: { done in opened += 1; release = done })
        #expect(opened == 1)
        release?()
        #expect(opened == 2)
    }

    @Test func aSpentPlanStopsClaimingWindows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let restore = self.restore(SessionState(windows: [
            SessionState.Window(targets: [fixture.root.path]),
        ]))
        restore.finish()
        #expect(!restore.isRestoring)
        #expect(restore.claimTarget() == nil)
    }

    @Test func aHalfRestoredArrangementIsNotWrittenDown() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let (store, defaults) = isolatedStore()
        let saved = SessionState(windows: [SessionState.Window(targets: [fixture.root.path])])
        store.save(saved)
        let restore = SessionRestore(store: store)
        restore.loadPlan()

        // Mid-restore the windows are still arriving; capturing now would write
        // down a fraction of the arrangement and lose the rest.
        restore.captureIfSettled()
        #expect(SessionStore(defaults: defaults).load() == saved)
    }
}

@Suite("Restored scans take the disk one at a time")
@MainActor
struct RestoreQueueTests {
    private func queue() -> SessionRestore {
        let (store, _) = isolatedStore()
        return SessionRestore(store: store)
    }

    @Test func onlyOneRestoredTabScansAtATime() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("one/big.bin", bytes: 2048)
        try fixture.file("two/big.bin", bytes: 2048)
        let restore = queue()

        let first = AppModel()
        let second = AppModel()
        restore.enqueue(first, target: fixture.root.appendingPathComponent("one"))
        restore.enqueue(second, target: fixture.root.appendingPathComponent("two"))

        // The first has the disk; the second is holding its target and waiting.
        #expect(first.isScanning)
        #expect(first.queuedTarget == nil)
        #expect(!second.isScanning)
        #expect(second.queuedTarget?.lastPathComponent == "two")
        // And it says so, rather than offering a start screen for a scan that
        // is already decided.
        #expect(second.scanTargetName == "two")
    }

    @Test func theNextScanStartsWhenTheOneBeforeItEnds() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("one/big.bin", bytes: 2048)
        try fixture.file("two/big.bin", bytes: 2048)
        let restore = queue()

        let first = AppModel()
        let second = AppModel()
        restore.enqueue(first, target: fixture.root.appendingPathComponent("one"))
        restore.enqueue(second, target: fixture.root.appendingPathComponent("two"))

        // Cancelling counts as ending: the queue must not stall on a scan the
        // user gave up on, or every tab behind it waits forever.
        first.cancelScan()
        for _ in 0 ..< 200 where !second.isScanning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(second.isScanning)
        #expect(second.queuedTarget == nil)
    }

    /// The button on a waiting tab goes through the queue, not around it.
    ///
    /// Scanning straight from the button would start a second walk of the disk
    /// beside the one already running — the one thing the queue exists to
    /// prevent — and leave a stale entry behind to be started all over again
    /// when the tab in front finished.
    @Test func scanNextTakesTheFrontOfTheQueueWithoutStartingASecondScan() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for name in ["running", "last", "impatient"] {
            try fixture.file("\(name)/big.bin", bytes: 2048)
        }
        let restore = queue()

        let running = AppModel()
        let last = AppModel()
        let impatient = AppModel()
        restore.enqueue(running, target: fixture.root.appendingPathComponent("running"))
        restore.enqueue(last, target: fixture.root.appendingPathComponent("last"))
        restore.enqueue(impatient, target: fixture.root.appendingPathComponent("impatient"))

        restore.scanNext(impatient)
        // Still only one scan: the tab in front keeps the disk, and minutes of
        // a volume walk are not thrown away to satisfy a button.
        #expect(running.isScanning)
        #expect(!impatient.isScanning)
        #expect(impatient.queuedTarget != nil)

        running.cancelScan()
        for _ in 0 ..< 200 where !impatient.isScanning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // It jumped the one that was queued before it.
        #expect(impatient.isScanning)
        #expect(!last.isScanning)
        #expect(last.queuedTarget != nil)
    }

    /// A tab that goes and scans something itself is no longer waiting, and the
    /// queue must not come back later and scan it a second time.
    @Test func aTabThatScansOnItsOwnDropsOutOfTheQueue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("running/big.bin", bytes: 2048)
        try fixture.file("queued/big.bin", bytes: 2048)
        try fixture.file("elsewhere/big.bin", bytes: 2048)
        let restore = queue()

        let running = AppModel()
        let wanderer = AppModel()
        restore.enqueue(running, target: fixture.root.appendingPathComponent("running"))
        restore.enqueue(wanderer, target: fixture.root.appendingPathComponent("queued"))

        // Off it goes to scan somewhere else entirely — from the menu, say.
        wanderer.scan(fixture.root.appendingPathComponent("elsewhere"))
        #expect(wanderer.queuedTarget == nil)
        let chosen = wanderer.scannedURL

        running.cancelScan()
        for _ in 0 ..< 100 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Still showing what it was asked for, not dragged back to the queue's
        // idea of what it was for.
        #expect(wanderer.scannedURL == chosen)
    }

    @Test func scanNextOnATabTheQueueHasForgottenStillScansIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("one/big.bin", bytes: 2048)
        let restore = queue()

        // A model holding a target but not in any queue — the plan was spent,
        // or the entry was swept. The button should still do the obvious thing.
        let stranded = AppModel()
        stranded.queuedTarget = fixture.root.appendingPathComponent("one")
        restore.scanNext(stranded)
        #expect(stranded.isScanning)
        #expect(stranded.queuedTarget == nil)
    }
}
