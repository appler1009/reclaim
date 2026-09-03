import Foundation
import Testing
@testable import DiskMap

@Suite("Nightly rescan")
@MainActor
struct NightlyRescanTests {
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
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: NightlyRescan.hourKey) }

        defaults.set(99, forKey: NightlyRescan.hourKey)
        #expect(NightlyRescan.hour == 23)
        defaults.set(-4, forKey: NightlyRescan.hourKey)
        #expect(NightlyRescan.hour == 0)
        defaults.removeObject(forKey: NightlyRescan.hourKey)
        #expect(NightlyRescan.hour == NightlyRescan.defaultHour)
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
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: NightlyRescan.enabledKey)
        defer { defaults.removeObject(forKey: NightlyRescan.enabledKey) }

        let schedule = NightlyRescan()
        schedule.reschedule()
        #expect(schedule.scheduledFor == nil, "a window with no scan has nothing to repeat")

        schedule.isArmed = true
        #expect(schedule.scheduledFor != nil)
    }

    @Test func switchingItOffUnbooksTheRun() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: NightlyRescan.enabledKey) }

        defaults.set(true, forKey: NightlyRescan.enabledKey)
        let schedule = NightlyRescan()
        schedule.isArmed = true
        #expect(schedule.scheduledFor != nil)

        defaults.set(false, forKey: NightlyRescan.enabledKey)
        schedule.reschedule()
        #expect(schedule.scheduledFor == nil)
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
    }
}
