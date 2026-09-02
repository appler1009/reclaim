import CoreGraphics
import Foundation

/// Decides when a scroll gesture has asked to change level.
///
/// Kept apart from the view so the feel can be tuned and tested without
/// synthesising AppKit events: everything here is arithmetic over a delta and a
/// timestamp. A step re-lays the whole map and moves the user somewhere else, so
/// the bar for triggering one is deliberately high.
struct ScrollNavigator {
    enum Step { case deeper, out }

    /// How much scrolling one step takes.
    var threshold: CGFloat = 6
    /// How long before another step is accepted.
    var cooldown: TimeInterval = 0.4
    /// A pause this long starts the accumulation over, so a slow drift across
    /// the map never adds up into a jump.
    var idleReset: TimeInterval = 0.2

    private var accumulated: CGFloat = 0
    private var lastEventAt = Date.distantPast
    private var readyAt = Date.distantPast

    /// Feeds one wheel event in. Returns a step only when the gesture has earned
    /// one; scrolling down goes deeper, matching the way the content moves.
    mutating func accept(delta: CGFloat,
                         at time: Date = Date(),
                         isMomentum: Bool = false,
                         isGestureStart: Bool = false) -> Step? {
        // Momentum is the trackpad coasting after the fingers have lifted. Acting
        // on it turns one flick into several levels, which is most of what makes
        // scroll navigation feel twitchy.
        guard !isMomentum else { return nil }
        if isGestureStart { accumulated = 0 }
        guard delta != 0 else { return nil }

        if time.timeIntervalSince(lastEventAt) > idleReset { accumulated = 0 }
        // Reversing starts again rather than unwinding what came before.
        if accumulated != 0, (accumulated < 0) != (delta < 0) { accumulated = 0 }
        lastEventAt = time
        accumulated += delta

        guard abs(accumulated) >= threshold, time >= readyAt else { return nil }
        let step: Step = accumulated < 0 ? .deeper : .out
        accumulated = 0
        readyAt = time.addingTimeInterval(cooldown)
        return step
    }

    /// Forgets any partial gesture, for when the map changes underfoot.
    mutating func reset() {
        accumulated = 0
    }
}
