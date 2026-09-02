import SwiftUI

/// Lets the menu bar act on whichever scan is in front.
///
/// Each window owns its own `AppModel` — a window is a scan — so menu commands
/// cannot hold one directly. They read this instead, which SwiftUI keeps
/// pointing at the focused window.
struct FocusedScanKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var scan: AppModel? {
        get { self[FocusedScanKey.self] }
        set { self[FocusedScanKey.self] = newValue }
    }
}
