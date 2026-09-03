import Foundation
import Testing
@testable import DiskMap

/// Serialized, and on its own defaults: the claim registry is process-global and
/// the settings are read from `UserDefaults`, so tests running side by side would
/// take each other's claims and see each other's flags.
@Suite("Nightly rescan", .serialized)
@MainActor
struct NightlyRescanTests {
    /// A defaults domain of its own, so nothing here can leave
    /// `NightlyRescanEnabled` switched on for the rest of the run.
    private func settings(enabled: Bool, hour: Int = 3) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "NightlyRescanTests")!
        defaults.removePersistentDomain(forName: "NightlyRescanTests")
        defaults.set(enabled, forKey: NightlyRescan.enabledKey)
        defaults.set(hour, forKey: NightlyRescan.hourKey)
        return defaults
    }
    /// A fixed zone, so the test means the same thing wherever it is run.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    @Test func theRunIsTheNextThreeAmToCome() {
        let next = NightlyRescan.nextRun(after: date(2026, 3, 10, 22, 30), hour: 3, calendar: calendar)
        #expect(next == date(2026, 3, 11, 3))
    }

    @Test func anHourAlreadyPassedTodayGoesToTomorrow() {
        let next = NightlyRescan.nextRun(after: date(2026, 3, 10, 9), hour: 3, calendar: calendar)
        #expect(next == date(2026, 3, 11, 3))
    }

    /// Asked of `Calendar` rather than by adding 86,400 seconds, so the run stays
    /// at three in the morning through the weekend the clocks go forward.
    @Test func theClocksChangingDoesNotMoveTheHour() {
        // British Summer Time starts 29 March 2026: 01:00 becomes 02:00.
        let next = NightlyRescan.nextRun(after: date(2026, 3, 28, 22), hour: 3, calendar: calendar)
        #expect(next == date(2026, 3, 29, 3))
        let components = calendar.dateComponents([.hour], from: next!)
        #expect(components.hour == 3, "the run should still be at three, not two or four")
    }

    @Test func theHourIsClampedToSomethingRunnable() {
        let defaults = settings(enabled: true)

        defaults.set(99, forKey: NightlyRescan.hourKey)
        #expect(NightlyRescan.hour(in: defaults) == 23)
        defaults.set(-4, forKey: NightlyRescan.hourKey)
        #expect(NightlyRescan.hour(in: defaults) == 0)
        defaults.removeObject(forKey: NightlyRescan.hourKey)
        #expect(NightlyRescan.hour(in: defaults) == NightlyRescan.defaultHour)
    }

    /// Two windows on one volume must not both start the same scan at 3am.
    @Test func onlyOneWindowTakesATarget() {
        NightlyRescan.releaseClaims()
        let night = date(2026, 3, 11, 3)
        #expect(NightlyRescan.claim("/Users/me", at: night))
        #expect(!NightlyRescan.claim("/Users/me", at: night.addingTimeInterval(2)))
        #expect(NightlyRescan.claim("/Volumes/Data", at: night), "a different target is its own run")
    }

    @Test func theNextNightIsItsOwnRun() {
        NightlyRescan.releaseClaims()
        #expect(NightlyRescan.claim("/Users/me", at: date(2026, 3, 11, 3)))
        #expect(NightlyRescan.claim("/Users/me", at: date(2026, 3, 12, 3)))
    }

    @Test func nothingIsScheduledUntilThereIsSomethingToRescan() {
        let schedule = NightlyRescan(defaults: settings(enabled: true), calendar: calendar)
        schedule.reschedule()
        #expect(schedule.scheduledFor == nil, "a window with no scan has nothing to repeat")

        schedule.isArmed = true
        #expect(schedule.scheduledFor != nil)
    }

    @Test func switchingItOffUnbooksTheRun() {
        let defaults = settings(enabled: true)
        let schedule = NightlyRescan(defaults: defaults, calendar: calendar)
        schedule.isArmed = true
        #expect(schedule.scheduledFor != nil)

        defaults.set(false, forKey: NightlyRescan.enabledKey)
        schedule.reschedule()
        #expect(schedule.scheduledFor == nil)
    }

    // MARK: - A night the machine slept through

    /// A timer does not fire while the Mac is asleep, so waking at ten finds the
    /// three o'clock booking still sitting there. Booking the next one without
    /// running it drops the night's scan — the case the schedule exists for.
    @Test func wakingUpAfterTheHourRunsTheScanThatWasMissed() {
        var clock = date(2026, 3, 10, 22)
        let schedule = NightlyRescan(now: { clock }, defaults: settings(enabled: true), calendar: calendar)
        var runs = 0
        schedule.action = { runs += 1 }
        schedule.isArmed = true
        let booked = try? #require(schedule.scheduledFor)
        #expect(runs == 0)

        // Asleep through 03:00, awake at 10:00.
        clock = date(2026, 3, 11, 10)
        schedule.reschedule()
        #expect(runs == 1, "the missed run should happen on waking")
        #expect(schedule.scheduledFor != booked, "and the next night should be booked after it")
        #expect(schedule.scheduledFor! > clock)
    }

    @Test func wakingUpBeforeTheHourRunsNothingEarly() {
        var clock = date(2026, 3, 10, 22)
        let schedule = NightlyRescan(now: { clock }, defaults: settings(enabled: true), calendar: calendar)
        var runs = 0
        schedule.action = { runs += 1 }
        schedule.isArmed = true

        clock = date(2026, 3, 11, 1)   // woke in the night, before three
        schedule.reschedule()
        #expect(runs == 0)
        #expect(schedule.scheduledFor == date(2026, 3, 11, 3))
    }

    /// Switching the schedule off is not a reason to run the night that was owed.
    @Test func anOverdueRunIsDroppedWhenItIsSwitchedOff() {
        var clock = date(2026, 3, 10, 22)
        let defaults = settings(enabled: true)
        let schedule = NightlyRescan(now: { clock }, defaults: defaults, calendar: calendar)
        var runs = 0
        schedule.action = { runs += 1 }
        schedule.isArmed = true

        clock = date(2026, 3, 11, 10)
        defaults.set(false, forKey: NightlyRescan.enabledKey)
        schedule.reschedule()
        #expect(runs == 0)
        #expect(schedule.scheduledFor == nil)
    }

    /// Every defaults write in the process posts this notification — window
    /// frames included — and rebooking on all of them would throw away a timer
    /// that is overdue but has not fired yet.
    @Test func anUnrelatedSettingChangingLeavesTheBookingAlone() {
        var clock = date(2026, 3, 10, 22)
        let defaults = settings(enabled: true)
        let schedule = NightlyRescan(now: { clock }, defaults: defaults, calendar: calendar)
        var runs = 0
        schedule.action = { runs += 1 }
        schedule.isArmed = true
        let booked = schedule.scheduledFor

        clock = date(2026, 3, 11, 10)
        defaults.set(920, forKey: "SomeOtherWindowWidth")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(runs == 0, "an unrelated write must not consume the overdue run")
        #expect(schedule.scheduledFor == booked, "nor rebook around it")
    }

    @Test func changingTheHourRebooks() {
        let clock = date(2026, 3, 10, 22)
        let defaults = settings(enabled: true)
        let schedule = NightlyRescan(now: { clock }, defaults: defaults, calendar: calendar)
        schedule.isArmed = true
        #expect(schedule.scheduledFor == date(2026, 3, 11, 3))

        defaults.set(5, forKey: NightlyRescan.hourKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(schedule.scheduledFor == date(2026, 3, 11, 5))
    }

    /// A rescan rebuilds the tree, which drops whatever was picked for the Trash.
    @Test func aWindowHoldingASelectionIsLeftAlone() throws {
        let model = AppModel()
        let root = FileItem(name: "/tmp/nightly", isDirectory: true, children: [
            FileItem(name: "big.bin", isDirectory: false, logicalSize: 900, physicalSize: 900),
        ])
        model.adoptForTesting(root: root, url: URL(fileURLWithPath: "/tmp/nightly"))
        #expect(model.canRescanUnattended)

        model.toggleStaged(root.children[0])
        #expect(!model.canRescanUnattended, "an overnight scan must not throw away the selection")

        model.toggleStaged(root.children[0])
        #expect(model.canRescanUnattended)
    }

    @Test func aWindowWithNothingScannedHasNothingToDo() {
        let model = AppModel()
        #expect(!model.canRescanUnattended)
        #expect(model.runNightlyRescan() == .nothingScanned)
    }

    /// A window part-way through a scan already has fresh numbers coming, but it
    /// must still hold the target: without that, a sibling window on the same
    /// volume takes the claim and starts the very same scan alongside it.
    @Test func aWindowAlreadyScanningStillHoldsItsTarget() {
        NightlyRescan.releaseClaims()
        let model = model(at: "/tmp/nightly-busy")
        model.isScanning = true

        #expect(model.runNightlyRescan() == .alreadyScanning)
        #expect(!NightlyRescan.claim("/tmp/nightly-busy"),
                "a sibling window must not be able to start the same scan")
    }

    /// The other way round: a window sitting out because of a selection leaves
    /// the target free, so a sibling with nothing picked can take the night.
    @Test func aWindowHoldingASelectionLeavesTheTargetFree() {
        NightlyRescan.releaseClaims()
        let model = model(at: "/tmp/nightly-staged")
        model.toggleStaged(model.scanRoot!.children[0])

        #expect(model.runNightlyRescan() == .itemsPickedForTrash)
        #expect(NightlyRescan.claim("/tmp/nightly-staged"),
                "a sibling with nothing picked should still get the run")
    }

    /// Uses a real directory: the winning window goes on to start an actual
    /// rescan, and it should have something to read.
    @Test func theSecondWindowOnATargetStandsDown() throws {
        NightlyRescan.releaseClaims()
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("big.bin", bytes: 4_000)

        let first = model(at: fixture.root.path)
        let second = model(at: fixture.root.path)

        #expect(first.runNightlyRescan() == .started)
        #expect(second.runNightlyRescan() == .anotherWindowHasIt)
        first.cancelScan()
    }

    /// A model with a tree already in place, standing in for a finished scan.
    private func model(at path: String) -> AppModel {
        let model = AppModel()
        let root = FileItem(name: path, isDirectory: true, children: [
            FileItem(name: "big.bin", isDirectory: false, logicalSize: 900, physicalSize: 900),
        ])
        model.adoptForTesting(root: root, url: URL(fileURLWithPath: path))
        return model
    }
}
