import CoreGraphics
import Foundation

/// The short zoom that connects one level of the map to the next.
///
/// Drilling into a tile grows that tile into the whole view; going back up
/// shrinks the view into the tile it came from. Without it the map simply
/// replaces itself and there is nothing to tell the eye where it landed.
struct TreemapTransition {
    let previous: TreemapLayout
    /// The tile the movement pivots around, in view coordinates.
    let focus: CGRect
    let goingIn: Bool
    let startedAt: Date
    let duration: TimeInterval

    static let defaultDuration: TimeInterval = 0.19

    init(previous: TreemapLayout, focus: CGRect, goingIn: Bool,
         duration: TimeInterval = TreemapTransition.defaultDuration) {
        self.previous = previous
        self.focus = focus
        self.goingIn = goingIn
        self.startedAt = Date()
        self.duration = duration
    }

    var isFinished: Bool { rawProgress >= 1 }

    private var rawProgress: CGFloat {
        guard duration > 0 else { return 1 }
        return min(1, CGFloat(Date().timeIntervalSince(startedAt) / duration))
    }

    /// Ease-out cubic: quick off the mark, settling at the end.
    var progress: CGFloat {
        let t = rawProgress
        return 1 - pow(1 - t, 3)
    }

    /// Transform for the layout being moved to, and how opaque it should be.
    func incoming(in bounds: CGRect) -> (transform: CGAffineTransform, alpha: CGFloat) {
        let p = progress
        let transform = goingIn
            ? Self.interpolate(from: Self.fit(focus, in: bounds), to: .identity, p: p)
            : Self.interpolate(from: Self.expand(focus, in: bounds), to: .identity, p: p)
        return (transform, min(1, p * 1.6))
    }

    /// Transform for the layout being left behind, and how opaque it should be.
    func outgoing(in bounds: CGRect) -> (transform: CGAffineTransform, alpha: CGFloat) {
        let p = progress
        let transform = goingIn
            ? Self.interpolate(from: .identity, to: Self.expand(focus, in: bounds), p: p)
            : Self.interpolate(from: .identity, to: Self.fit(focus, in: bounds), p: p)
        return (transform, max(0, 1 - p * 1.4))
    }

    /// Maps the full bounds onto `rect` — the whole map shrunk into one tile.
    private static func fit(_ rect: CGRect, in bounds: CGRect) -> CGAffineTransform {
        guard bounds.width > 0, bounds.height > 0 else { return .identity }
        return CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
    }

    /// Maps `rect` onto the full bounds — one tile blown up to fill the view.
    private static func expand(_ rect: CGRect, in bounds: CGRect) -> CGAffineTransform {
        guard rect.width > 0.5, rect.height > 0.5 else { return .identity }
        let scaleX = bounds.width / rect.width
        let scaleY = bounds.height / rect.height
        return CGAffineTransform(scaleX: scaleX, y: scaleY)
            .translatedBy(x: -rect.minX, y: -rect.minY)
    }

    private static func interpolate(from: CGAffineTransform,
                                    to: CGAffineTransform,
                                    p: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: from.a + (to.a - from.a) * p,
                          b: from.b + (to.b - from.b) * p,
                          c: from.c + (to.c - from.c) * p,
                          d: from.d + (to.d - from.d) * p,
                          tx: from.tx + (to.tx - from.tx) * p,
                          ty: from.ty + (to.ty - from.ty) * p)
    }
}
