import CoreGraphics
import Foundation
import Testing
@testable import DiskMap

@Suite("Zoom transition")
struct TransitionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let focus = CGRect(x: 200, y: 150, width: 200, height: 150)

    private func transition(goingIn: Bool, duration: TimeInterval = 30) -> TreemapTransition {
        TreemapTransition(previous: TreemapLayout(), focus: focus,
                          goingIn: goingIn, duration: duration)
    }

    @Test func drillingInStartsWithTheNewMapInsideTheTileItCameFrom() {
        let start = transition(goingIn: true).incoming(in: bounds)
        let placed = bounds.applying(start.transform)
        #expect(abs(placed.minX - focus.minX) < 1)
        #expect(abs(placed.minY - focus.minY) < 1)
        #expect(abs(placed.width - focus.width) < 1)
        #expect(abs(placed.height - focus.height) < 1)
    }

    @Test func drillingInPushesTheOldMapOutwards() {
        let start = transition(goingIn: true).outgoing(in: bounds)
        // It begins untouched and only then expands.
        #expect(abs(bounds.applying(start.transform).width - bounds.width) < 1)
        #expect(start.alpha > 0.9)
    }

    @Test func goingBackUpStartsZoomedIntoTheFolderBeingLeft() {
        let start = transition(goingIn: false).incoming(in: bounds)
        let placed = focus.applying(start.transform)
        #expect(abs(placed.width - bounds.width) < 1)
        #expect(abs(placed.height - bounds.height) < 1)
    }

    @Test func aFinishedTransitionIsTheIdentity() {
        let finished = transition(goingIn: true, duration: 0)
        #expect(finished.isFinished)
        let placed = bounds.applying(finished.incoming(in: bounds).transform)
        #expect(abs(placed.width - bounds.width) < 0.01)
        #expect(abs(placed.minX) < 0.01)
        #expect(finished.incoming(in: bounds).alpha >= 1)
        #expect(finished.outgoing(in: bounds).alpha <= 0)
    }

    @Test func easingRunsFromZeroToOneWithoutOvershooting() {
        let quick = transition(goingIn: true, duration: 0.05)
        #expect(quick.progress >= 0 && quick.progress <= 1)
        Thread.sleep(forTimeInterval: 0.08)
        #expect(quick.progress == 1)
        #expect(quick.isFinished)
    }

    @Test func degenerateTilesDoNotProduceInvalidTransforms() {
        // A sliver of a tile must not divide the transform by ~zero.
        let sliver = TreemapTransition(previous: TreemapLayout(),
                                       focus: CGRect(x: 10, y: 10, width: 0.1, height: 0.1),
                                       goingIn: false, duration: 30)
        let transform = sliver.incoming(in: bounds).transform
        #expect(transform.a.isFinite && transform.d.isFinite)
        #expect(transform.tx.isFinite && transform.ty.isFinite)
    }
}
