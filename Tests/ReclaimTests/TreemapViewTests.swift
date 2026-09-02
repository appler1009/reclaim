import AppKit
import Testing
@testable import DiskMap

@Suite("Map view")
@MainActor
struct TreemapViewTests {
    private final class Recorder: TreemapViewDelegate {
        var hovered: [FileItem?] = []
        func treemap(_ view: TreemapView, didHover cell: TreemapCell?) { hovered.append(cell?.item) }
        func treemap(_ view: TreemapView, didSelect cell: TreemapCell?) {}
        func treemap(_ view: TreemapView, didActivate item: FileItem) {}
        func treemapDidRequestUp(_ view: TreemapView) {}
    }

    private func tree() -> FileItem {
        let children: [FileItem] = (0 ..< 6).map { index in
            let size = UInt64(600 - index * 80)
            let name = "child-" + String(index)
            return FileItem(name: name, isDirectory: false,
                            logicalSize: size, physicalSize: size)
        }
        let root = FileItem(name: "/tmp/view", isDirectory: true, children: children)
        root.physicalSize = children.reduce(0) { $0 + $1.physicalSize }
        root.children.sort { $0.physicalSize > $1.physicalSize }
        return root
    }

    @Test func resizingClearsTheHoverHighlight() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let recorder = Recorder()
        view.delegate = recorder
        view.show(root: tree())

        view.mouseMoved(with: mouseEvent(at: NSPoint(x: 100, y: 100)))
        #expect(recorder.hovered.count == 1)
        #expect(recorder.hovered[0] != nil, "the pointer should have picked up a tile")

        // A divider drag must not leave a highlight pinned to an old rectangle.
        view.isResizing = true
        #expect(recorder.hovered.count == 2)
        #expect(recorder.hovered[1] == nil, "resizing should clear the hover")
    }

    @Test func hoverIsIgnoredWhileResizing() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let recorder = Recorder()
        view.delegate = recorder
        view.show(root: tree())
        view.isResizing = true

        view.mouseMoved(with: mouseEvent(at: NSPoint(x: 200, y: 200)))
        #expect(recorder.hovered.isEmpty)
    }

    @Test func resizingTheViewRelaysOutForTheNewSize() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.show(root: tree())
        view.setFrameSize(NSSize(width: 300, height: 400))
        // Drawing must not trip over a layout built for the old width.
        let image = NSImage(size: NSSize(width: 300, height: 400))
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
        #expect(view.bounds.width == 300)
    }

    private func mouseEvent(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 0, pressure: 0)!
    }
}
