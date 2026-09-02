import CoreGraphics
import Foundation
import Testing
@testable import DiskMap

@Suite("Scroll sensitivity")
struct ScrollNavigatorTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// One notch of a mouse wheel, or a small trackpad movement.
    private let notch: CGFloat = -1

    @Test func oneNotchDoesNotChangeLevel() {
        var navigator = ScrollNavigator()
        #expect(navigator.accept(delta: notch, at: start) == nil)
    }

    @Test func aDeliberateScrollTakesOneStep() {
        var navigator = ScrollNavigator()
        var steps: [ScrollNavigator.Step] = []
        for tick in 0 ..< 8 {
            if let step = navigator.accept(delta: notch,
                                           at: start.addingTimeInterval(Double(tick) * 0.01)) {
                steps.append(step)
            }
        }
        #expect(steps == [.deeper], "one gesture is one level, not several")
    }

    @Test func heldScrollingDescendsAtAControlledRate() {
        var navigator = ScrollNavigator()
        var steps = 0
        // Half a second of continuous scrolling at 60Hz. Holding the gesture
        // should keep going deeper — just at the cooldown's pace, not once per
        // event, which is what made this feel twitchy.
        for tick in 0 ..< 30 {
            if navigator.accept(delta: notch,
                                at: start.addingTimeInterval(Double(tick) / 60)) != nil {
                steps += 1
            }
        }
        #expect(steps <= 2, "half a second of scrolling crossed \(steps) levels")
        #expect(steps >= 1, "sustained scrolling should still get somewhere")
    }

    @Test func momentumAfterTheFingersLiftIsIgnored() {
        var navigator = ScrollNavigator()
        var steps = 0
        for tick in 0 ..< 8 where navigator.accept(delta: notch,
                                                   at: start.addingTimeInterval(Double(tick) * 0.01)) != nil {
            steps += 1
        }
        // The trackpad keeps coasting long after the gesture ended.
        for tick in 0 ..< 60 {
            let time = start.addingTimeInterval(1 + Double(tick) * 0.01)
            #expect(navigator.accept(delta: notch, at: time, isMomentum: true) == nil)
        }
        #expect(steps == 1)
    }

    @Test func aPauseStartsTheGestureOver() {
        var navigator = ScrollNavigator()
        // Almost enough, then the hand stops.
        for tick in 0 ..< 5 {
            _ = navigator.accept(delta: notch, at: start.addingTimeInterval(Double(tick) * 0.01))
        }
        // A single nudge much later must not tip it over the edge.
        #expect(navigator.accept(delta: notch, at: start.addingTimeInterval(5)) == nil)
    }

    @Test func reversingCountsFromScratch() {
        var navigator = ScrollNavigator()
        for tick in 0 ..< 5 {
            _ = navigator.accept(delta: notch, at: start.addingTimeInterval(Double(tick) * 0.01))
        }
        var steps: [ScrollNavigator.Step] = []
        for tick in 5 ..< 13 {
            if let step = navigator.accept(delta: -notch,
                                           at: start.addingTimeInterval(Double(tick) * 0.01)) {
                steps.append(step)
            }
        }
        #expect(steps == [.out], "reversal should not have to unwind the earlier scroll first")
    }

    @Test func aSecondStepIsAllowedOnceTheCooldownPasses() {
        var navigator = ScrollNavigator()
        var steps = 0
        for tick in 0 ..< 8 where navigator.accept(delta: notch,
                                                   at: start.addingTimeInterval(Double(tick) * 0.01)) != nil {
            steps += 1
        }
        // A fresh gesture, well after the cooldown.
        for tick in 0 ..< 8 {
            let time = start.addingTimeInterval(1 + Double(tick) * 0.01)
            if navigator.accept(delta: notch, at: time) != nil { steps += 1 }
        }
        #expect(steps == 2)
    }

    @Test func aFlickOfTrackpadDeltasIsStillOneStep() {
        var navigator = ScrollNavigator()
        var steps = 0
        // Precise deltas arrive far more often and larger; the view scales them
        // down before this point, which is what keeps a flick to a single level.
        for tick in 0 ..< 40 {
            let delta: CGFloat = -24 / 8
            if navigator.accept(delta: delta,
                                at: start.addingTimeInterval(Double(tick) / 120)) != nil {
                steps += 1
            }
        }
        #expect(steps <= 1, "a third of a second of flicking should not cross \(steps) levels")
    }

    @Test func resetForgetsAPartialGesture() {
        var navigator = ScrollNavigator()
        for tick in 0 ..< 5 {
            _ = navigator.accept(delta: notch, at: start.addingTimeInterval(Double(tick) * 0.01))
        }
        navigator.reset()
        #expect(navigator.accept(delta: notch, at: start.addingTimeInterval(0.06)) == nil)
    }
}
