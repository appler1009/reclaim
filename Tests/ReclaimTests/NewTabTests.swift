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
        front.orderFront(nil)
    }

    func open() { opened = true; made.orderFront(nil) }
    func windows() -> [NSWindow] { opened ? [front, made] : [front] }

    /// Runs the action and waits for the turn of the run loop it finishes on.
    func newTab() async -> NSWindow? {
        await withCheckedContinuation { continuation in
            _ = NewTab.open(front: front,
                            openWindow: { self.open() },
                            windows: { self.windows() },
                            then: { continuation.resume(returning: $0) })
        }
    }
}

@MainActor
@Suite("New Tab")
struct NewTabTests {
    @Test func theNewWindowJoinsTheOneInFront() async {
        // The whole point: `newWindowForTab:` on its own produces a window
        // standing beside the front one unless the system happens to prefer
        // tabs, and a menu item called New Tab has to make a tab regardless.
        let scene = FakeScene()
        let created = await scene.newTab()

        #expect(created === scene.made)
        #expect(scene.front.tabGroup?.windows.contains(scene.made) == true)
        #expect(scene.front.tabGroup?.windows.count == 2)
    }

    @Test func aWindowAppKitAlreadyTabbedIsLeftAlone() async {
        // Where the system does prefer tabs, AppKit gets there first; adding it
        // a second time must not shuffle the group.
        let scene = FakeScene()
        scene.open()
        scene.front.addTabbedWindow(scene.made, ordered: .above)

        _ = await scene.newTab()
        #expect(scene.front.tabGroup?.windows.count == 2, "still one tab, not two of the same")
    }

    @Test func theBorrowedTabbingModeIsGivenBack() async {
        let scene = FakeScene()
        scene.front.tabbingMode = .automatic
        _ = await scene.newTab()
        #expect(scene.front.tabbingMode == .automatic,
                "the front window is left as it was found")
    }

    @Test func withNoWindowInFrontThereIsNothingToTabOnto() {
        var opened = false
        #expect(NewTab.open(front: nil, openWindow: { opened = true }, windows: { [] }) == false)
        #expect(!opened, "and no window is made either")
    }
}
