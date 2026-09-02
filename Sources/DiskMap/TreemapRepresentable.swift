import SwiftUI

struct TreemapRepresentable: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> TreemapView {
        let view = TreemapView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: TreemapView, context: Context) {
        context.coordinator.model = model
        if view.root !== model.zoomRoot { view.show(root: model.zoomRoot) }
        if view.measure != model.measure { view.measure = model.measure }
        if view.focusWaste != model.focusWaste { view.focusWaste = model.focusWaste }
        if context.coordinator.appliedWasteRevision != model.wasteRevision {
            context.coordinator.appliedWasteRevision = model.wasteRevision
            view.wasteMarks = model.wasteMarks
        }
        let staged = model.stagedMarks
        if view.stagedMarks != staged { view.stagedMarks = staged }
        if view.selectedItemIdentity !== model.selectedItem { view.select(model.selectedItem) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: TreemapViewDelegate {
        var model: AppModel
        var appliedWasteRevision = -1
        init(model: AppModel) { self.model = model }

        nonisolated func treemap(_ view: TreemapView, didHover cell: TreemapCell?) {
            MainActor.assumeIsolated { model.hoverItem = cell?.item }
        }
        nonisolated func treemap(_ view: TreemapView, didSelect cell: TreemapCell?) {
            MainActor.assumeIsolated { model.selectedItem = cell?.item }
        }
        nonisolated func treemap(_ view: TreemapView, didActivate item: FileItem) {
            MainActor.assumeIsolated { model.zoom(into: item) }
        }
    }
}
