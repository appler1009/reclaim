import AppKit
import Testing
@testable import DiskMap

@Suite("Map view")
@MainActor
struct TreemapViewTests {
    private final class Recorder: TreemapViewDelegate {
        var hovered: [FileItem?] = []
        var selected: [FileItem?] = []
        var trashRequests: [FileItem] = []
        var revealRequests: [FileItem] = []
        var selectionToggles: [FileItem] = []
        var stagedItems: Set<ObjectIdentifier> = []

        func treemap(_ view: TreemapView, didHover cell: TreemapCell?) { hovered.append(cell?.item) }
        func treemap(_ view: TreemapView, didSelect cell: TreemapCell?) { selected.append(cell?.item) }
        func treemap(_ view: TreemapView, didActivate item: FileItem) {}
        func treemapDidRequestUp(_ view: TreemapView) {}
        func treemap(_ view: TreemapView, didRequestTrash item: FileItem) { trashRequests.append(item) }
        func treemap(_ view: TreemapView, didRequestReveal item: FileItem) { revealRequests.append(item) }
        func treemap(_ view: TreemapView, didToggleSelection item: FileItem) { selectionToggles.append(item) }
        func treemap(_ view: TreemapView, isStaged item: FileItem) -> Bool {
            stagedItems.contains(ObjectIdentifier(item))
        }
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

    @Test func aRowHoverLightsItsTile() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let recorder = Recorder()
        view.delegate = recorder
        let root = tree()
        view.show(root: root)

        view.highlight(root.children[1])
        #expect(view.highlighted === root.children[1])
        #expect(recorder.hovered.isEmpty, "a highlight from the list must not be echoed back to it")

        view.highlight(nil)
        #expect(view.highlighted == nil)
    }

    @Test func thePointerOwnsTheOutlineItIsAlreadyDrawing() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let recorder = Recorder()
        view.delegate = recorder
        view.show(root: tree())

        view.mouseMoved(with: mouseEvent(at: NSPoint(x: 100, y: 100)))
        let underPointer = try? #require(recorder.hovered.first ?? nil)

        // The list is told about the map's hover too, and echoes it straight
        // back; the tile must not end up outlined twice.
        view.highlight(underPointer)
        #expect(view.highlighted == nil)
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

@Suite("Map refresh")
@MainActor
struct TreemapRefreshTests {
    private func tree() -> FileItem {
        let a = FileItem(name: "a", isDirectory: false, logicalSize: 900, physicalSize: 900)
        let b = FileItem(name: "b", isDirectory: false, logicalSize: 600, physicalSize: 600)
        let c = FileItem(name: "c", isDirectory: false, logicalSize: 300, physicalSize: 300)
        let root = FileItem(name: "/tmp/refresh", isDirectory: true, children: [a, b, c])
        root.physicalSize = 1_800
        root.children.sort { $0.physicalSize > $1.physicalSize }
        return root
    }

    @Test func reloadPicksUpAnItemThatWasDeleted() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let root = tree()
        view.show(root: root)
        #expect(view.laidOutItemsForTesting.count == 3)

        // Same folder, one child gone: the map must not keep drawing it.
        let doomed = root.children[0]
        root.remove(child: doomed)
        view.reload()

        let names = view.laidOutItemsForTesting.map(\.name)
        #expect(names.count == 2)
        #expect(!names.contains(doomed.name))
    }

    @Test func reloadKeepsShowingTheSameFolder() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let root = tree()
        view.show(root: root)
        view.reload()
        #expect(view.root === root)
    }
}

@Suite("Map context menu")
@MainActor
struct TreemapMenuTests {
    private final class Recorder: TreemapViewDelegate {
        var trashRequests: [FileItem] = []
        var revealRequests: [FileItem] = []
        var selectionToggles: [FileItem] = []
        var activated: [FileItem] = []
        var selected: [FileItem?] = []
        var staged: Set<ObjectIdentifier> = []

        func treemap(_ view: TreemapView, didHover cell: TreemapCell?) {}
        func treemap(_ view: TreemapView, didSelect cell: TreemapCell?) { selected.append(cell?.item) }
        func treemap(_ view: TreemapView, didActivate item: FileItem) { activated.append(item) }
        func treemapDidRequestUp(_ view: TreemapView) {}
        func treemap(_ view: TreemapView, didRequestTrash item: FileItem) { trashRequests.append(item) }
        func treemap(_ view: TreemapView, didRequestReveal item: FileItem) { revealRequests.append(item) }
        func treemap(_ view: TreemapView, didToggleSelection item: FileItem) { selectionToggles.append(item) }
        func treemap(_ view: TreemapView, isStaged item: FileItem) -> Bool {
            staged.contains(ObjectIdentifier(item))
        }
    }

    private func tree() -> FileItem {
        let inner = FileItem(name: "inner.bin", isDirectory: false,
                             logicalSize: 400, physicalSize: 400)
        let folder = FileItem(name: "folder", isDirectory: true, children: [inner])
        folder.physicalSize = 400
        let file = FileItem(name: "loose.bin", isDirectory: false,
                            logicalSize: 900, physicalSize: 900)
        let root = FileItem(name: "/tmp/menu", isDirectory: true, children: [folder, file])
        root.physicalSize = 1_300
        root.children.sort { $0.physicalSize > $1.physicalSize }
        return root
    }

    private func view() -> (TreemapView, Recorder) {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let recorder = Recorder()
        view.delegate = recorder
        view.show(root: tree())
        return (view, recorder)
    }

    private func rightClick(_ view: TreemapView, at point: NSPoint) -> NSMenu? {
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return view.menu(for: event)
    }

    @Test func rightClickingATileOffersTrashAndFinder() throws {
        let (view, _) = view()
        let menu = try #require(rightClick(view, at: NSPoint(x: 60, y: 60)))
        let titles = menu.items.map(\.title)
        #expect(titles.contains { $0.contains("Move") && $0.contains("Trash") })
        #expect(titles.contains("Reveal in Finder"))
        #expect(titles.contains("Copy Path"))
        #expect(titles.contains("Select for Trash"))
    }

    @Test func theMenuNamesTheTileItActsOn() throws {
        let (view, _) = view()
        let menu = try #require(rightClick(view, at: NSPoint(x: 60, y: 60)))
        let heading = try #require(menu.items.first)
        #expect(heading.title.contains("loose.bin") || heading.title.contains("folder"))
        #expect(!heading.isEnabled, "the heading is a label, not an action")
    }

    @Test func rightClickingAlsoSelectsTheTile() throws {
        let (view, recorder) = view()
        _ = rightClick(view, at: NSPoint(x: 60, y: 60))
        #expect(recorder.selected.count == 1)
        #expect(view.selectedItemIdentity != nil)
    }

    @Test func choosingMoveToTrashAsksForThatItem() throws {
        let (view, recorder) = view()
        let menu = try #require(rightClick(view, at: NSPoint(x: 60, y: 60)))
        let trashItem = try #require(menu.items.first { $0.title.contains("Trash")
                                                        && $0.title.hasPrefix("Move") })
        _ = trashItem.target?.perform(trashItem.action, with: trashItem)
        #expect(recorder.trashRequests.count == 1)
        #expect(recorder.trashRequests.first === view.selectedItemIdentity)
    }

    @Test func theSelectionEntryFollowsWhatIsAlreadyTicked() throws {
        let (view, recorder) = view()
        let firstTile = try #require(view.laidOutItemsForTesting.first)
        recorder.staged = [ObjectIdentifier(firstTile)]

        let menu = try #require(rightClick(view, at: NSPoint(x: 60, y: 60)))
        #expect(menu.items.map(\.title).contains("Remove from Selection"))
    }

    @Test func clickingEmptySpaceOffersNoMenu() {
        let view = TreemapView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.delegate = Recorder()
        // No scan loaded: nothing to act on.
        #expect(rightClick(view, at: NSPoint(x: 10, y: 10)) == nil)
    }
}
