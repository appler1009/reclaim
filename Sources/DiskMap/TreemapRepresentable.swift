import SwiftUI

struct TreemapRepresentable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    /// True while the sidebar divider is being dragged.
    var isResizing = false

    func makeNSView(context: Context) -> TreemapView {
        let view = TreemapView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TreemapView, context: Context) {
        context.coordinator.model = model
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
        init(model: AppModel) { self.model = model }

        nonisolated func treemap(_ view: TreemapView, didHover cell: TreemapCell?) {
            MainActor.assumeIsolated { model.setHover(cell?.item) }
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
    }
}
