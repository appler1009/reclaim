import Combine
import SwiftUI

struct TreemapRepresentable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    /// True while the sidebar divider is being dragged.
    var isResizing = false

    func makeNSView(context: Context) -> TreemapView {
        let view = TreemapView()
        view.delegate = context.coordinator
        context.coordinator.follow(hoverOf: model, in: view)
        return view
    }

    func updateNSView(_ view: TreemapView, context: Context) {
        context.coordinator.model = model
        context.coordinator.follow(hoverOf: model, in: view)
        if view.root !== model.zoomRoot {
            view.show(root: model.zoomRoot)
        } else if context.coordinator.appliedTreeRevision != model.treeRevision {
            // Same folder, different contents: something was trashed.
            view.reload()
        }
        context.coordinator.appliedTreeRevision = model.treeRevision
        if view.measure != model.measure { view.measure = model.measure }
        if view.isResizing != isResizing { view.isResizing = isResizing }
        let staged = model.stagedMarks
        if view.stagedMarks != staged { view.stagedMarks = staged }
        if view.selectedItemIdentity !== model.selectedItem { view.select(model.selectedItem) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: TreemapViewDelegate {
        var model: AppModel
        var appliedTreeRevision = 0
        private var hoverObserver: AnyCancellable?
        private var observedHover: HoverState?
        private weak var observedView: TreemapView?
        /// The tile the map last reported the pointer as being on.
        private var mapHover: FileItem?
        init(model: AppModel) { self.model = model }

        /// Mirrors the shared hover onto the map, so a row hovered in the
        /// contents list lights its tile.
        ///
        /// Subscribed straight to `HoverState` rather than read in
        /// `updateNSView`: hover changes on every mouse move, and going through
        /// SwiftUI would put a view update on each one — the cost this state was
        /// split out of `AppModel` to avoid.
        ///
        /// Keyed on the map as well as the hover: SwiftUI keeps the coordinator
        /// across a new `makeNSView`, and a subscription still holding the
        /// replaced view would leave list-driven outlines quietly dead.
        func follow(hoverOf model: AppModel, in view: TreemapView) {
            guard model.hover !== observedHover || view !== observedView else { return }
            observedHover = model.hover
            observedView = view
            hoverObserver = model.hover.$item.sink { [weak view] item in
                MainActor.assumeIsolated { view?.highlight(item) }
            }
            // A fresh map starts blank, so hand it whatever is hovered already.
            view.highlight(model.hover.item)
        }

        nonisolated func treemap(_ view: TreemapView, didHover cell: TreemapCell?) {
            MainActor.assumeIsolated {
                // Leaving the map clears the hover only while the map's own tile
                // is still the one held: crossing the splitter can deliver the
                // row's entry before the map's exit, and an unguarded clear then
                // blanked the highlight the pointer had just moved onto.
                if let item = cell?.item {
                    mapHover = item
                    model.setHover(item)
                } else if let departed = mapHover {
                    mapHover = nil
                    model.setHover(departed, isHovered: false)
                }
            }
        }
        nonisolated func treemap(_ view: TreemapView, didSelect cell: TreemapCell?) {
            MainActor.assumeIsolated { model.setSelection(cell?.item) }
        }
        nonisolated func treemap(_ view: TreemapView, didActivate item: FileItem) {
            MainActor.assumeIsolated { model.zoom(into: item) }
        }
        nonisolated func treemapDidRequestUp(_ view: TreemapView) {
            MainActor.assumeIsolated { model.zoomOut() }
        }
        nonisolated func treemap(_ view: TreemapView, didRequestTrash item: FileItem) {
            MainActor.assumeIsolated {
                let model = self.model
                Task { await model.trash([item]) }
            }
        }
        nonisolated func treemap(_ view: TreemapView, didRequestReveal item: FileItem) {
            MainActor.assumeIsolated { model.revealInFinder(item) }
        }
        nonisolated func treemap(_ view: TreemapView, didToggleSelection item: FileItem) {
            MainActor.assumeIsolated { model.toggleStaged(item) }
        }
        nonisolated func treemap(_ view: TreemapView, isStaged item: FileItem) -> Bool {
            MainActor.assumeIsolated { model.isStaged(item) }
        }
    }
}
