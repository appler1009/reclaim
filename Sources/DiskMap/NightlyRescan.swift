import AppKit
import Foundation

/// Rescans overnight what a window already has open.
///
/// Deliberately in-app and per-window: the target is whatever that window is
/// showing, so nothing is scheduled until a scan has happened, and closing the
/// window ends it. A Mac asleep at the hour runs nothing — the timer fires when
/// it wakes, which is late but still the night's scan, and the next one is
/// computed from the clock rather than by adding 24 hours to the last, so a run
/// that slipped does not drag every later run with it.
/// What a window decided when the hour came.
enum NightlyRescanOutcome: String {
    case started
    case nothingScanned
    case itemsPickedForTrash
    case anotherWindowHasIt
    case alreadyScanning
}

@MainActor
final class NightlyRescan {
    /// Whether windows rescan their target overnight. Off until asked for: a
    /// whole-volume scan is real disk work to start on somebody's behalf.
    static let enabledKey = "NightlyRescanEnabled"
    /// The hour to run at, 0–23, local time.
    static let hourKey = "NightlyRescanHour"
    static let defaultHour = 3

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The configured hour, clamped: a nonsense value in defaults should not
    /// stop the scan from ever being scheduled.
    static func hour(in defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: hourKey) as? Int else { return defaultHour }
        return min(max(stored, 0), 23)
    }

    /// The next `hour` o'clock strictly after `date`.
    ///
    /// Asked of `Calendar` rather than worked out in seconds so the clocks going
    /// forward or back does not move the run to two or four in the morning.
    static func nextRun(after date: Date, hour: Int, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: date,
                          matching: DateComponents(hour: hour, minute: 0, second: 0),
                          matchingPolicy: .nextTime)
    }

    // MARK: - One run per target per night

    /// When each target was last claimed for an overnight rescan.
    ///
    /// Two windows on the same volume would otherwise both start the same scan
    /// at three in the morning, doubling the disk work and writing two snapshots
    /// an instant apart. The first window to wake takes the target; the second
    /// finds it taken and leaves its own numbers to be refreshed by hand.
    private static var claims: [String: Date] = [:]

    /// Takes `target` for tonight's run, or returns false if a window already has.
    static func claim(_ target: String, at date: Date = Date(), within: TimeInterval = 3600) -> Bool {
        if let held = claims[target], date.timeIntervalSince(held) < within, date >= held {
            return false
        }
        claims[target] = date
        return true
    }

    static func releaseClaims() { claims.removeAll() }

    // MARK: - Scheduling

    /// Run when the hour comes round. Set by the model that owns this schedule.
    var action: (() -> Void)?

    /// Whether this window has something to rescan. Nothing is scheduled without it.
    var isArmed = false {
        didSet { guard isArmed != oldValue else { return }; reschedule() }
    }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let now: () -> Date
    private let defaults: UserDefaults
    private let calendar: Calendar
    /// The settings the current booking was made from, so a defaults write that
    /// has nothing to do with this can be ignored.
    private var bookedFrom: (enabled: Bool, hour: Int)

    /// How late a run may be and still count as the one that was due, rather
    /// than as the next one coming up. Matches the timer's own tolerance.
    private static let slack: TimeInterval = 60

    init(now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard,
         calendar: Calendar = .current) {
        self.now = now
        self.defaults = defaults
        self.calendar = calendar
        self.bookedFrom = (Self.isEnabled(in: defaults), Self.hour(in: defaults))
        let workspace = NSWorkspace.shared.notificationCenter
        // Waking, and the clock being changed under us, both invalidate a fire
        // date that was worked out in the old world.
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        })
        // Every defaults write in the process comes through here, the window
        // frames included. Rebooking on all of them would throw away a timer
        // that is overdue but has not fired yet, so only a change to this
        // schedule's own settings is acted on.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescheduleIfSettingsChanged() }
        })
    }

    deinit {
        timer?.invalidate()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The moment the next run is booked for, or nil when none is.
    private(set) var scheduledFor: Date?

    /// Books the next run, first honouring one that has already come due.
    ///
    /// A timer does not fire while the machine is asleep, so at ten in the
    /// morning the three o'clock booking is still sitting there overdue. Simply
    /// asking for the next three o'clock after now would book tomorrow and drop
    /// the night's scan — the very case this schedule exists to cover — so an
    /// overdue booking is run before the next one is made. The clock being set
    /// forward past the fire date lands here the same way.
    func reschedule() {
        let due = scheduledFor
        timer?.invalidate()
        timer = nil
        scheduledFor = nil
        // Switched off in the meantime: nothing is owed and nothing is booked.
        guard isArmed, Self.isEnabled(in: defaults) else { return }
        if let due, now() >= due.addingTimeInterval(-Self.slack) { action?() }
        book()
    }

    private func rescheduleIfSettingsChanged() {
        let current = (enabled: Self.isEnabled(in: defaults), hour: Self.hour(in: defaults))
        guard current != bookedFrom else { return }
        reschedule()
    }

    /// Puts the next run on the clock, without regard for any that was missed.
    private func book() {
        bookedFrom = (Self.isEnabled(in: defaults), Self.hour(in: defaults))
        guard isArmed, bookedFrom.enabled,
              let next = Self.nextRun(after: now(), hour: bookedFrom.hour,
                                      calendar: calendar) else { return }
        scheduledFor = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Cleared before the run, so booking the next one does not read
                // this fire date as a night that was missed.
                self.scheduledFor = nil
                self.action?()
                // Book the next from the clock, not by adding a day to this one.
                self.book()
            }
        }
        // The scan is nowhere near this precise, and a loose timer lets the
        // system fire it alongside whatever else it was going to wake for.
        timer.tolerance = Self.slack
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
