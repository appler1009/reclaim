import AppKit
import SwiftUI

/// Draggable split between the map and the list.
enum SidebarWidth {
    static let minimum: Double = 280
    static let maximum: Double = 760
    static let `default`: Double = 372
    static let storageKey = "sidebarWidth"

    /// Kept within bounds so the map always has room left, whatever ends up in
    /// preferences — including a stale value from a much wider window.
    static func clamped(_ width: Double) -> Double {
        guard !width.isNaN else { return `default` }
        return min(maximum, max(minimum, width))   // infinities clamp to the bounds
    }
}

/// The hairline between the panes, with a wider invisible grab area.
struct PaneDivider: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || widthAtDragStart != nil ? Color.ember.opacity(0.55) : Color.hairline)
            .frame(width: 1)
            .overlay(
                // The grab area is wider than the line it draws, or the divider
                // would be a one-pixel target.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = widthAtDragStart ?? width
                                if widthAtDragStart == nil { widthAtDragStart = start }
                                // The sidebar is on the right: dragging left widens it.
                                width = SidebarWidth.clamped(start - value.translation.width)
                            }
                            .onEnded { _ in widthAtDragStart = nil }
                    )
            )
            .accessibilityLabel("Resize sidebar")
    }
}
