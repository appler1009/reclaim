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

    @Test func scanningAQueuedTabByHandClearsItsWait() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("one/big.bin", bytes: 2048)
        let restore = queue()

        let waiting = AppModel()
        restore.enqueue(AppModel(), target: fixture.root)
        restore.enqueue(waiting, target: fixture.root.appendingPathComponent("one"))
        #expect(waiting.queuedTarget != nil)

        // The button on a waiting tab: it stops waiting and scans.
        waiting.scan(fixture.root.appendingPathComponent("one"))
        #expect(waiting.queuedTarget == nil)
        #expect(waiting.isScanning)
    }
}
