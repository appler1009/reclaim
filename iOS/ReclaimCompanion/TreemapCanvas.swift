import ReclaimKit
import SwiftUI

/// The folder in view as a single level of tiles, sized by what they hold.
///
/// One level, like the Mac: a mosaic of sub-pixel specks is a picture of a
/// disk, not a thing anyone can point at — and on a phone, a tile has to be big
/// enough for a fingertip.
struct TreemapCanvas: View {
    let children: [CompanionAPI.NodeChild]
    /// Drawn with a brighter edge, and the row that goes with it in the list.
    var selected: String?
    /// True while the divider is being dragged. The layout is held still and
    /// stretched instead of being recomputed, because a squarified layout is
    /// not continuous in the height it is given: a tile that no longer fits a
    /// row moves to the next one, and every neighbour shuffles after it. Doing
    /// that sixty times a second is the flicker.
    var isResizing = false
    var onTap: (CompanionAPI.NodeChild) -> Void

    /// The size the tiles below were laid out for, which during a drag is not
    /// the size they are being drawn in.
    @State private var laidOutFor: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let tiles = layout(in: laidOutFor == .zero ? size : laidOutFor)
            let scale = stretch(from: laidOutFor == .zero ? size : laidOutFor, to: size)
            Canvas { context, _ in
                // Fills first, all of them, then the selected border: a tile
                // drawn later would otherwise paint over the edge of one drawn
                // earlier, which is what chewed the corners of a selected tile.
                for tile in tiles {
                    draw(tile, scaled: scale, in: &context)
                }
                if let tile = tiles.first(where: { $0.child.path == selected }) {
                    outline(tile, scaled: scale, in: &context)
                }
            }
            // One tap, and it does what tapping the same thing in the list
            // does. There is no pointer here to hover with, so a tile that
            // needed a second gesture to open would be a tile nobody opens.
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { event in
                if let hit = tiles.hit(event.location, scaled: scale) { onTap(hit.child) }
            })
            .onAppear { laidOutFor = size }
            // Held still while the divider moves, and settled once it stops.
            .onChange(of: size) { _, new in
                if !isResizing { laidOutFor = new }
            }
            .onChange(of: isResizing) { _, resizing in
                if !resizing { laidOutFor = size }
            }
            .onChange(of: children) { _, _ in laidOutFor = size }
        }
        .background(Theme.background)
        // Square, and not clipped: a treemap fills its rectangle exactly, so a
        // rounded corner has nothing to round off except a real tile — the one
        // in the bottom-right lost a bite of itself to it.
        .border(Theme.hairline, width: 0.5)
    }

    fileprivate struct Placed {
        let child: CompanionAPI.NodeChild
        let rect: CGRect
    }

    private func layout(in size: CGSize) -> [Placed] {
        Squarify.layout(weights: children.map { Double($0.bytes) },
                        in: CGRect(origin: .zero, size: size))
            .map { Placed(child: children[$0.index], rect: $0.rect) }
    }

    private func stretch(from laid: CGSize, to shown: CGSize) -> CGSize {
        guard laid.width > 0, laid.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: shown.width / laid.width, height: shown.height / laid.height)
    }

    /// The tile's own border, drawn just inside its edge so that a rounded
    /// corner is the fill's corner and the stroke sits on top of it — half a
    /// stroke hanging outside is half a stroke for a neighbour to paint over.
    private func border(_ rect: CGRect, width: CGFloat) -> Path {
        let inner = rect.insetBy(dx: width / 2, dy: width / 2)
        guard inner.width > 0, inner.height > 0 else { return Path(rect) }
        return Path(roundedRect: inner,
                    cornerRadius: max(0, radius(for: rect) - width / 2))
    }

    /// Barely rounded: enough to tell two touching tiles apart, not enough to
    /// eat the corner of a small one.
    private func radius(for rect: CGRect) -> CGFloat {
        min(3, min(rect.width, rect.height) / 5)
    }

    private func draw(_ tile: Placed, scaled: CGSize, in context: inout GraphicsContext) {
        let inset = tile.rect.applying(.init(scaleX: scaled.width, y: scaled.height))
            .insetBy(dx: 1, dy: 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let colour = tile.child.family.color

        context.fill(Path(roundedRect: inset, cornerRadius: radius(for: inset)),
                     with: .color(colour.opacity(tile.child.isDirectory ? 0.55 : 0.8)))
        context.stroke(border(inset, width: 0.75), with: .color(colour.opacity(0.9)),
                       lineWidth: 0.75)

        // A label only where one fits: half a word is worse than none.
        guard inset.width > 54, inset.height > 26 else { return }
        let text = context.resolve(Text(tile.child.name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white))
        let name = text.measure(in: CGSize(width: inset.width - 10, height: 14))
        context.draw(text, at: CGPoint(x: inset.minX + 6, y: inset.minY + 6), anchor: .topLeading)

        guard inset.height > 26 + name.height else { return }
        let size = context.resolve(Text(tile.child.human)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.85)))
        context.draw(size, at: CGPoint(x: inset.minX + 6, y: inset.minY + 8 + name.height),
                     anchor: .topLeading)
    }

    private func outline(_ tile: Placed, scaled: CGSize, in context: inout GraphicsContext) {
        let inset = tile.rect.applying(.init(scaleX: scaled.width, y: scaled.height))
            .insetBy(dx: 1, dy: 1)
        guard inset.width > 0, inset.height > 0 else { return }
        context.stroke(border(inset, width: 2), with: .color(.white), lineWidth: 2)
    }
}

private extension Array where Element == TreemapCanvas.Placed {
    /// Tiles are laid largest-first, so the last match is the smallest one
    /// under the finger.
    func hit(_ point: CGPoint, scaled: CGSize) -> Element? {
        last { $0.rect.applying(.init(scaleX: scaled.width, y: scaled.height)).contains(point) }
    }
}
