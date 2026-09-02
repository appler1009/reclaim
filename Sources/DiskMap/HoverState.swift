import SwiftUI

/// What the pointer is currently over.
///
/// Split out of `AppModel` on purpose: hover changes on every mouse move, and
/// as part of the main model each move invalidated the entire view tree.
@MainActor
final class HoverState: ObservableObject {
    @Published private(set) var item: FileItem?

    func set(_ item: FileItem?) {
        guard item !== self.item else { return }
        self.item = item
    }
}
