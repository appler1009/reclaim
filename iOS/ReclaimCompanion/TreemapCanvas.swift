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
    var onTap: (CompanionAPI.NodeChild) -> Void

    var body: some View {
        GeometryReader { geometry in
            let tiles = layout(in: geometry.size)
            Canvas { context, _ in
                for tile in tiles {
                    draw(tile, in: &context)
                }
            }
            // One tap, and it does what tapping the same thing in the list
            // does. There is no pointer here to hover with, so a tile that
            // needed a second gesture to open would be a tile nobody opens.
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { event in
                if let hit = tiles.hit(event.location) { onTap(hit.child) }
            })
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hairline))
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

    private func draw(_ tile: Placed, in context: inout GraphicsContext) {
        let inset = tile.rect.insetBy(dx: 1, dy: 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let isSelected = tile.child.path == selected
        let shape = Path(roundedRect: inset,
                         cornerRadius: min(6, min(inset.width, inset.height) / 4))
        let colour = tile.child.family.color

        context.fill(shape, with: .color(colour.opacity(tile.child.isDirectory ? 0.55 : 0.8)))
        context.stroke(shape,
                       with: .color(isSelected ? .white : colour.opacity(0.9)),
                       lineWidth: isSelected ? 2 : 0.75)

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
}

private extension Array where Element == TreemapCanvas.Placed {
    /// Tiles are laid largest-first, so the last match is the smallest one
    /// under the finger.
    func hit(_ point: CGPoint) -> Element? {
        last { $0.rect.contains(point) }
    }
}
