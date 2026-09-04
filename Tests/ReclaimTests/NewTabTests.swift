import AppKit
import Testing
@testable import DiskMap

/// Stands in for AppKit making a window: it does not exist until asked for,
/// exactly as the real one does not exist before the action runs.
@MainActor
private final class FakeScene {
    let front: NSWindow
    let made: NSWindow
    private var opened = false

    init(identifier: String = "reclaim-test") {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        front = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        made = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        front.tabbingIdentifier = identifier
        made.tabbingIdentifier = identifier
        // A programmatically made window frees itself when closed, which would
        // leave these references dangling the moment the test tidies up.
        front.isReleasedWhenClosed = false
        made.isReleasedWhenClosed = false
        front.orderFront(nil)
    }

    /// What AppKit does when it makes the window: reveals it, and — where the
    /// system already prefers tabs — joins it to the front one itself.
    func open(joiningItself: Bool = false) {
        opened = true
        made.orderFront(nil)
        if joiningItself { front.addTabbedWindow(made, ordered: .above) }
    }

    /// The window does not exist until it is made, or `before` would already
    /// hold it and the action would have nothing to find.
    func windows() -> [NSWindow] { opened ? [front, made] : [front] }

    /// Runs the action and waits for it to settle.
    func newTab(open: (() -> Void)? = nil) async -> NSWindow? {
        await withCheckedContinuation { continuation in
            _ = NewTab.open(front: front,
                            openWindow: open ?? { self.open() },
                            windows: { self.windows() },
                            then: { continuation.resume(returning: $0) })
        }
    }

    /// Windows left ordered in stay key for the next test, and Swift Testing
    /// makes no promise about order.
    func close() { made.close(); front.close() }
}

@MainActor
@Suite("New Tab")
struct NewTabTests {
    @Test func theNewWindowJoinsTheOneInFront() async {
        // The whole point: `newWindowForTab:` on its own produces a window
        // standing beside the front one unless the system happens to prefer
        // tabs, and a menu item called New Tab has to make a tab regardless.
        let scene = FakeScene()
        defer { scene.close() }
        let created = await scene.newTab()

        #expect(created === scene.made)
        #expect(scene.front.tabGroup?.windows.contains(scene.made) == true)
        #expect(scene.front.tabGroup?.windows.count == 2)
    }

    @Test func aWindowAppKitAlreadyTabbedIsLeftAlone() async {
        // Where the system does prefer tabs, AppKit gets there first. The
        // window has to appear *during* the action, or it is already in the
        // "before" set and this never reaches the skip it is testing.
        let scene = FakeScene()
        defer { scene.close() }
        let created = await scene.newTab(open: { scene.open(joiningItself: true) })

        #expect(created === scene.made, "found, even though it needed no joining")
        #expect(scene.front.tabGroup?.windows.count == 2, "still one tab, not two of the same")
    }

    @Test func aWindowThatArrivesLateIsStillTabbed() async {
        // The case the run loop makes real: SwiftUI builds the scene after the
        // action returns, and not always by the next turn. Restoring the
        // tabbing mode or giving up on that first turn is what left a second
        // window standing beside the first.
        let scene = FakeScene()
        defer { scene.close() }
        let created = await scene.newTab(open: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { scene.open() }
        })

        #expect(created === scene.made)
        #expect(scene.front.tabGroup?.windows.contains(scene.made) == true)
    }

    @Test func aWindowThatNeverArrivesGivesUpAndPutsThingsBack() async {
        let scene = FakeScene()
        defer { scene.close() }
        scene.front.tabbingMode = .automatic
        // Nothing is ever made: the action must not hold the borrowed mode, or
        // wait, for ever.
        let created = await scene.newTab(open: {})

        #expect(created == nil)
        #expect(scene.front.tabbingMode == .automatic, "given back even when nothing came")
    }

    @Test func theBorrowedTabbingModeIsGivenBack() async {
        let scene = FakeScene()
        defer { scene.close() }
        scene.front.tabbingMode = .automatic
        _ = await scene.newTab()
        #expect(scene.front.tabbingMode == .automatic,
                "the front window is left as it was found")
    }

    @Test func withNoWindowInFrontThereIsNothingToTabOnto() {
        // `front` is what the menu item hands over — the window of the scan it
        // was enabled for — so nil means nil, with no falling back to whatever
        // the app happens to have lying around key.
        var opened = false
        #expect(NewTab.open(front: nil, openWindow: { opened = true }, windows: { [] }) == false)
        #expect(!opened, "and no window is made either")
    }
}
