import AppKit
import SwiftUI

/// Keeps a window's tab label in step with what it is showing.
///
/// A window has two names: `title`, shown in the title bar, and `tab.title`,
/// shown in the tab bar. `navigationTitle` sets the first. The second keeps
/// whatever it was given when the window was created — the scene's name — which
/// is why the window opened at launch sat in the tab bar as "Reclaim" while
/// later tabs, created after their scan, read correctly.
struct WindowTabTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let title = self.title
        // The view has no window on the first update pass.
        DispatchQueue.main.async {
            guard let window = view.window, window.tab.title != title else { return }
            Log.debug("tab renamed", ["from": window.tab.title, "to": title])
            window.tab.title = title
        }
    }
}
