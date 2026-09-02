import CoreGraphics

/// Works out whether a window needs correcting, and to what.
///
/// Split out of the window guard because the guard's mistakes were geometric:
/// it centred a window that only needed resizing, and judged windows against a
/// screen they were not on. Both are testable as arithmetic; neither was, while
/// this lived inside an AppKit notification handler.
enum WindowFit {
    /// A window is "oversized" once it takes this much of the screen. Beyond it,
    /// AppKit's own re-fitting is what put it there, not the user.
    static let oversizedFraction: CGFloat = 0.9

    static func isOversized(_ size: CGSize, on visible: CGRect) -> Bool {
        size.width >= visible.width * oversizedFraction
            || size.height >= visible.height * oversizedFraction
    }

    /// The frame a window should take, or nil when it is fine as it is.
    ///
    /// The origin is kept: a window that needs shrinking does not need moving,
    /// and moving it is the more startling of the two. It shifts only far enough
    /// to stay on screen.
    static func correction(for frame: CGRect,
                           in visible: CGRect,
                           preferred: CGSize) -> CGRect? {
        guard isOversized(frame.size, on: visible) else { return nil }

        let size = CGSize(width: min(preferred.width, visible.width * oversizedFraction),
                          height: min(preferred.height, visible.height * oversizedFraction))
        let origin = CGPoint(
            x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
            y: min(max(frame.minY, visible.minY), visible.maxY - size.height))
        let corrected = CGRect(origin: origin, size: size)
        return corrected == frame ? nil : corrected
    }

    /// Where a window should open when nothing better is known: the middle.
    static func centred(_ size: CGSize, in visible: CGRect) -> CGRect {
        CGRect(x: visible.midX - size.width / 2,
               y: visible.midY - size.height / 2,
               width: size.width, height: size.height)
    }
}
