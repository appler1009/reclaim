import ReclaimKit
import SwiftUI

/// The Mac app's own chrome, so the two read as one product.
enum Theme {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.086)
    static let panel = Color(red: 0.086, green: 0.098, blue: 0.129)
    static let raised = Color(red: 0.125, green: 0.141, blue: 0.180)
    static let hairline = Color.white.opacity(0.08)
    static let ember = Color(red: 1.00, green: 0.42, blue: 0.36)
    static let caution = Color(red: 0.98, green: 0.72, blue: 0.30)
}

extension FileFamily {
    var color: Color {
        let (red, green, blue) = rgb
        return Color(red: red, green: green, blue: blue)
    }
}

extension View {
    /// A card of content on the app's dark ground.
    func panel() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline))
    }
}

extension String {
    /// The Mac's home folder written the way people write it, so a path is not
    /// three quarters `/Users/somebody`.
    ///
    /// Matched by shape rather than against a known home: this app is on a
    /// phone and has no idea what the Mac's user is called, and `/Users/<name>`
    /// is what a macOS home folder is.
    var abbreviatingMacHome: String {
        let parts = split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2, parts[0].isEmpty, parts[1] == "Users", !parts[2].isEmpty else {
            return self
        }
        return "~/" + parts.dropFirst(3).joined(separator: "/")
    }
}
