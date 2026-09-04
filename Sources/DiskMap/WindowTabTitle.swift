import AppKit
import SwiftUI

/// Keeps a window's tab label in step with what it is showing, and tells the
/// model which window is showing it.
///
/// A window has two names: `title`, shown in the title bar, and `tab.title`,
/// shown in the tab bar. `navigationTitle` sets the first. The second keeps
/// whatever it was given when the window was created — the scene's name — which
/// is why the window opened at launch sat in the tab bar as "Reclaim" while
/// later tabs, created after their scan, read correctly.
struct WindowTabTitle: NSViewRepresentable {
    let title: String
    /// Handed the window this view landed in. A scan otherwise has no way to
    /// name its own window, and File-menu items that act on "the window in
    /// front" have to mean the same one the menu was enabled for — not
    /// whatever happens to be key when the item is picked.
    var window: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let title = self.title
        let record = self.window
        // The view has no window on the first update pass.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            record(window)
            // Only for a window already in a tab group. Reaching for `window.tab`
            // on an untabbed window makes AppKit materialise one, and that showed
            // up as a phantom second window at every launch.
            guard window.tabGroup != nil, window.tab.title != title else { return }
            window.tab.title = title
        }
    }
}
