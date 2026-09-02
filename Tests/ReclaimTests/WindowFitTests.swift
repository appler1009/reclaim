import CoreGraphics
import Testing
@testable import DiskMap

@Suite("Window fit")
struct WindowFitTests {
    /// A large external display, and a window sitting off to one side of it.
    private let screen = CGRect(x: 0, y: 0, width: 3840, height: 2100)
    private let preferred = CGSize(width: 1320, height: 860)

    @Test func aWindowThatFitsIsLeftAlone() {
        let window = CGRect(x: 200, y: 150, width: 1320, height: 860)
        #expect(WindowFit.correction(for: window, in: screen, preferred: preferred) == nil)
    }

    @Test func rightClickingOffCentreDoesNotMoveTheWindow() {
        // The bug: any correction re-centred the window, so a stray check while a
        // context menu was open teleported it to the middle of the display.
        let window = CGRect(x: 120, y: 90, width: 3800, height: 2050)
        let corrected = try? #require(WindowFit.correction(for: window, in: screen,
                                                           preferred: preferred))
        #expect(corrected?.origin.x == 120, "the window should stay where it was put")
        #expect(corrected?.origin.y == 90)
        #expect(corrected?.size == preferred, "only the size needed fixing")
    }

    @Test func aCorrectedWindowIsNudgedBackOnScreen() {
        // Only when keeping the origin would push it off the edge.
        let window = CGRect(x: 3700, y: 2000, width: 3800, height: 2050)
        let corrected = try? #require(WindowFit.correction(for: window, in: screen,
                                                           preferred: preferred))
        #expect(corrected?.maxX ?? 0 <= screen.maxX)
        #expect(corrected?.maxY ?? 0 <= screen.maxY)
        #expect(corrected?.minX ?? 0 >= screen.minX)
    }

    @Test func aWindowOnASmallerScreenIsJudgedByThatScreen() {
        // The same window is fine on a large display and oversized on a laptop.
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let window = CGRect(x: 40, y: 40, width: 1440, height: 900)
        #expect(WindowFit.correction(for: window, in: screen, preferred: preferred) == nil)
        #expect(WindowFit.correction(for: window, in: laptop, preferred: preferred) != nil)
    }

    @Test func aWindowFillingTheScreenIsTreatedAsOversized() {
        #expect(WindowFit.isOversized(CGSize(width: 3840, height: 2100), on: screen))
        #expect(WindowFit.isOversized(CGSize(width: 3456, height: 400), on: screen),
                "either dimension is enough")
        #expect(!WindowFit.isOversized(CGSize(width: 1320, height: 860), on: screen))
    }

    @Test func correctionNeverExceedsTheScreen() {
        // Even asked for something huge, it stays inside the visible frame.
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let corrected = try? #require(WindowFit.correction(
            for: CGRect(x: 0, y: 0, width: 1500, height: 940),
            in: laptop,
            preferred: CGSize(width: 5000, height: 5000)))
        #expect(corrected?.width ?? 0 <= laptop.width)
        #expect(corrected?.height ?? 0 <= laptop.height)
    }

    @Test func centringIsAvailableForAWindowWithNoHistory() {
        let frame = WindowFit.centred(preferred, in: screen)
        #expect(frame.midX == screen.midX)
        #expect(frame.midY == screen.midY)
        #expect(frame.size == preferred)
    }
}
