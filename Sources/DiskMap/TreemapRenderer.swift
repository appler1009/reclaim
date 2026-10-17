import AppKit
import ReclaimKit

/// Draws a laid-out treemap into a context, as a city seen from above.
///
/// Every tile is a city block: its area is still its share of the folder, and
/// what is built on it says what is in it — a tech campus for code, a school for
/// documents, a landfill for caches and other things that are rebuilt on
/// demand (`District`). Roofs carry the family colour, so the colour legend in
/// the sidebar still matches the map.
///
/// Split out of the view so it can be measured off-screen: rendering a
/// full-detail map is the other half of the resize budget, next to layout.
enum TreemapRenderer {
    /// Colour per family, resolved once — `NSColor.blended` allocates, and doing
    /// it per cell showed up as pure overhead for ~100k cells.
    private static let roofs: [CGColor] = FileFamily.allCases.map { $0.color.cgColor }
    private static let walls: [CGColor] = FileFamily.allCases.map {
        ($0.color.blended(withFraction: 0.55, of: .black) ?? $0.color).cgColor
    }
    /// Tiles too small to build on are painted as a plain roof, a little dimmed.
    private static let specks: [CGColor] = FileFamily.allCases.map {
        ($0.color.blended(withFraction: 0.25, of: .black) ?? $0.color).cgColor
    }

    static let asphalt = CGColor(srgbRed: 0.075, green: 0.082, blue: 0.105, alpha: 1)
    private static let stagedWash = Theme.accent.withAlphaComponent(0.38).cgColor

    /// The district a cell is drawn as. `rootWithin` is whether the folder in
    /// view is itself inside something rebuildable, worked out once per draw.
    static func district(of cell: TreemapCell, in layout: TreemapLayout,
                         measure: SizeMeasure, rootWithin: Bool) -> District {
        var inside = rootWithin
        if !inside {
            // Only cells below the first level have folders between them and the root.
            var node = cell.item.parent
            while let current = node, current !== layout.root {
                if current.isReclaimableByName { inside = true; break }
                node = current.parent
            }
        }
        return District.of(cell.item, family: cell.item.dominantFamily(measure),
                           insideReclaimable: inside)
    }

    /// `fillBackground` is off while a transition composites two layouts over
    /// one another — the second pass must not paint out the first.
    static func draw(layout: TreemapLayout,
                     in context: CGContext,
                     dirty: CGRect,
                     measure: SizeMeasure,
                     staged: Set<ObjectIdentifier>,
                     fillBackground: Bool = true) {
        if fillBackground {
            context.setFillColor(asphalt)
            context.fill(dirty)
        }
        let rootWithin = layout.root?.isWithinReclaimable ?? false

        for cell in layout.cells {
            let rect = cell.rect
            guard rect.width > 0.3, rect.height > 0.3, rect.intersects(dirty) else { continue }
            let family = cell.item.dominantFamily(measure)
            let isStaged = !staged.isEmpty && staged.contains(ObjectIdentifier(cell.item))

            // A full-detail map has ~100k of these; they get colour and nothing else.
            guard rect.width >= 6, rect.height >= 6 else {
                context.setFillColor(isStaged ? stagedWash : specks[family.index])
                context.fill(rect)
                continue
            }

            let district = self.district(of: cell, in: layout, measure: measure,
                                          rootWithin: rootWithin)
            CityBlock.draw(district: district,
                           roof: roofs[family.index],
                           wall: walls[family.index],
                           in: rect,
                           seed: CityBlock.seed(cell.item.name),
                           context: context)

            if isStaged {
                context.setFillColor(stagedWash)
                context.fill(rect)
                if rect.width > 8 && rect.height > 8 {
                    context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                    context.setLineWidth(1.5)
                    context.stroke(rect.insetBy(dx: 1, dy: 1))
                }
            }
        }

        // Folder boundaries are strokes over the tiles, never gaps between them.
        context.setLineWidth(1)
        for frame in layout.folderFrames
        where frame.rect.width > 12 && frame.rect.height > 12 && frame.rect.intersects(dirty) {
            let alpha = max(0.05, 0.34 - CGFloat(frame.depth) * 0.06)
            context.setStrokeColor(NSColor(white: 0, alpha: alpha).cgColor)
            context.stroke(frame.rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

/// Paints one city block.
///
/// Everything on a block is placed by a generator seeded from the item's name,
/// so a folder looks the same every time it is drawn — while resizing, across
/// launches — and only its size changes how much fits on it. Object counts are
/// capped, so a huge tile costs about what a large one does.
enum CityBlock {
    /// FNV-1a over the name. `hashValue` is reseeded every launch, which would
    /// rebuild the whole town each time the app opened.
    static func seed(_ name: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func draw(district: District, roof: CGColor, wall: CGColor,
                     in rect: CGRect, seed: UInt64, context: CGContext) {
        // Half a street on every side, so neighbouring blocks share one road.
        let street = min(3, max(0.75, min(rect.width, rect.height) * 0.05))
        let block = rect.insetBy(dx: street, dy: street)
        guard block.width > 1, block.height > 1 else { return }

        let radius = min(4, min(block.width, block.height) * 0.18)
        context.setFillColor(sidewalk)
        context.addPath(CGPath(roundedRect: block, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
        context.fillPath()

        let curb = block.width > 14 && block.height > 14 ? 1.5 : 0.5
        let lot = block.insetBy(dx: curb, dy: curb)
        context.setFillColor(ground(district))
        context.fill(lot)

        // Too small for scenery: a single roof says what the block is.
        guard lot.width >= 16, lot.height >= 16 else {
            let pad = min(lot.width, lot.height) * 0.2
            context.setFillColor(district == .landfill ? Scenery.dirt[1] : roof)
            context.fill(lot.insetBy(dx: pad, dy: pad))
            return
        }

        context.saveGState()
        context.clip(to: lot)
        var painter = Painter(context: context, rng: SplitMix64(seed: seed),
                              lot: lot, roof: roof, wall: wall)
        switch district {
        case .techCampus: painter.techCampus()
        case .dataCenter: painter.dataCenter()
        case .school: painter.school()
        case .stadium: painter.stadium()
        case .park: painter.park()
        case .warehouse: painter.warehouse()
        case .factory: painter.factory()
        case .utility: painter.utility()
        case .housing: painter.housing()
        case .landfill: painter.landfill()
        }
        context.restoreGState()
    }

    private static let sidewalk = CGColor(srgbRed: 0.22, green: 0.23, blue: 0.26, alpha: 1)

    private static func ground(_ district: District) -> CGColor {
        switch district {
        case .techCampus: return CGColor(srgbRed: 0.15, green: 0.18, blue: 0.21, alpha: 1)
        case .dataCenter: return CGColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
        case .school: return CGColor(srgbRed: 0.16, green: 0.20, blue: 0.16, alpha: 1)
        case .stadium: return CGColor(srgbRed: 0.15, green: 0.17, blue: 0.16, alpha: 1)
        case .park: return CGColor(srgbRed: 0.13, green: 0.25, blue: 0.15, alpha: 1)
        case .warehouse: return CGColor(srgbRed: 0.18, green: 0.17, blue: 0.15, alpha: 1)
        case .factory: return CGColor(srgbRed: 0.17, green: 0.16, blue: 0.16, alpha: 1)
        case .utility: return CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
        case .housing: return CGColor(srgbRed: 0.15, green: 0.19, blue: 0.15, alpha: 1)
        case .landfill: return Scenery.dirt[0]
        }
    }
}

/// Fixed colours for the scenery that is not tied to a file family.
private enum Scenery {
    static let dirt: [CGColor] = [
        CGColor(srgbRed: 0.27, green: 0.22, blue: 0.14, alpha: 1),
        CGColor(srgbRed: 0.36, green: 0.29, blue: 0.18, alpha: 1),
        CGColor(srgbRed: 0.43, green: 0.35, blue: 0.21, alpha: 1),
        CGColor(srgbRed: 0.50, green: 0.41, blue: 0.25, alpha: 1),
    ]
    static let debris: [CGColor] = [
        CGColor(srgbRed: 0.80, green: 0.32, blue: 0.28, alpha: 1),
        CGColor(srgbRed: 0.30, green: 0.52, blue: 0.80, alpha: 1),
        CGColor(srgbRed: 0.88, green: 0.80, blue: 0.42, alpha: 1),
        CGColor(srgbRed: 0.70, green: 0.70, blue: 0.72, alpha: 1),
        CGColor(srgbRed: 0.34, green: 0.62, blue: 0.40, alpha: 1),
        CGColor(srgbRed: 0.92, green: 0.92, blue: 0.90, alpha: 1),
    ]
    static let foliage: [CGColor] = [
        CGColor(srgbRed: 0.20, green: 0.42, blue: 0.24, alpha: 1),
        CGColor(srgbRed: 0.24, green: 0.50, blue: 0.27, alpha: 1),
        CGColor(srgbRed: 0.17, green: 0.36, blue: 0.22, alpha: 1),
    ]
    static let turf = CGColor(srgbRed: 0.22, green: 0.48, blue: 0.28, alpha: 1)
    static let water = CGColor(srgbRed: 0.22, green: 0.42, blue: 0.62, alpha: 1)
    static let path = CGColor(srgbRed: 0.62, green: 0.58, blue: 0.48, alpha: 0.55)
    static let concrete = CGColor(srgbRed: 0.42, green: 0.43, blue: 0.46, alpha: 1)
    static let litWindow = CGColor(srgbRed: 1.00, green: 0.92, blue: 0.62, alpha: 0.85)
    static let glassWindow = CGColor(srgbRed: 0.70, green: 0.92, blue: 1.00, alpha: 0.80)
    static let shadow = CGColor(gray: 0, alpha: 0.30)
    static let chalk = CGColor(gray: 1, alpha: 0.70)
    static let smoke = CGColor(gray: 0.85, alpha: 0.22)
    static let caution = CGColor(srgbRed: 0.95, green: 0.74, blue: 0.20, alpha: 1)
    static let rubber = CGColor(gray: 0.08, alpha: 1)
    static let flag = CGColor(srgbRed: 0.90, green: 0.30, blue: 0.28, alpha: 1)
    static let floodlight = CGColor(srgbRed: 1.00, green: 0.96, blue: 0.70, alpha: 0.30)
}

/// A small, fast, seedable generator, so scenery is the same on every draw.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func between(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }
    mutating func chance(_ odds: CGFloat) -> Bool { unit() < odds }
    mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
}

/// Draws the scenery for one district onto a lot (already clipped).
private struct Painter {
    let context: CGContext
    var rng: SplitMix64
    let lot: CGRect
    let roof: CGColor
    let wall: CGColor

    /// The scale things are drawn at: grows with the block, within limits, so a
    /// big block gets more buildings rather than one enormous one.
    var unit: CGFloat { min(12, max(3, (lot.width * lot.height).squareRoot() / 10)) }
    var area: CGFloat { lot.width * lot.height }

    /// How many of something fit, at roughly `perUnit` square units each.
    func count(perUnits squareUnits: CGFloat, max ceiling: Int, min floor: Int = 1) -> Int {
        let fits = Int(area / (unit * unit * squareUnits))
        return Swift.max(floor, Swift.min(ceiling, fits))
    }

    // MARK: Primitives

    func fill(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    func oval(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: rect)
    }

    func ring(_ rect: CGRect, _ color: CGColor, width: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokeEllipse(in: rect)
    }

    func line(_ from: CGPoint, _ to: CGPoint, _ color: CGColor, width: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    /// A building seen from slightly south: the roof sits `height` above the
    /// footprint, with the front wall showing below it and a shadow to the east.
    /// The footprint is pushed down so the roof never leaves `space`.
    mutating func building(in space: CGRect, height: CGFloat, roof: CGColor, wall: CGColor,
                  windows: CGColor? = nil) {
        let height = min(height, space.height * 0.6)
        let footprint = CGRect(x: space.minX, y: space.minY + height,
                               width: space.width, height: space.height - height)
        guard footprint.width > 1, footprint.height > 1 else { return }
        let top = footprint.offsetBy(dx: 0, dy: -height)
        fill(CGRect(x: footprint.maxX, y: top.minY + height * 0.5,
                    width: height * 0.55, height: footprint.height + height * 0.5), Scenery.shadow)
        let front = CGRect(x: footprint.minX, y: top.maxY, width: footprint.width, height: height)
        fill(front, wall)
        fill(top, roof)
        // A lit edge along the roof's north side reads as daylight on the parapet.
        fill(CGRect(x: top.minX, y: top.minY, width: top.width, height: 0.75),
             CGColor(gray: 1, alpha: 0.18))

        if let windows, front.height >= 5, front.width >= 5 {
            let pitch: CGFloat = front.height > 24 ? 3.5 : 3
            let columns = Int((front.width - 2) / pitch)
            let rows = Int((front.height - 2) / pitch)
            guard columns > 0, rows > 0, columns * rows <= 600 else { return }
            context.setFillColor(windows)
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    // Draws the generator either way, so the pattern does not
                    // depend on which windows happen to be lit.
                    let lit = rng.unitIsLit()
                    guard lit else { continue }
                    context.fill(CGRect(x: front.minX + 1.5 + CGFloat(column) * pitch,
                                        y: front.minY + 1.5 + CGFloat(row) * pitch,
                                        width: pitch * 0.5, height: pitch * 0.45))
                }
            }
        }
    }

    mutating func tree(at center: CGPoint, radius: CGFloat) {
        oval(CGRect(x: center.x - radius + radius * 0.35, y: center.y - radius + radius * 0.35,
                    width: radius * 2, height: radius * 2), Scenery.shadow)
        oval(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
             rng.pick(Scenery.foliage))
        let glint = radius * 0.45
        oval(CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.6,
                    width: glint, height: glint), CGColor(gray: 1, alpha: 0.12))
    }

    mutating func scatterTrees(_ number: Int, in region: CGRect, size: CGFloat) {
        guard region.width > size, region.height > size else { return }
        for _ in 0 ..< number {
            let radius = rng.between(size * 0.35, size * 0.6)
            tree(at: CGPoint(x: rng.between(region.minX + radius, region.maxX - radius),
                             y: rng.between(region.minY + radius, region.maxY - radius)),
                 radius: radius)
        }
    }

    /// Splits `rect` into at least `count` cells, as square as the shape allows.
    func grid(_ rect: CGRect, count: Int) -> [CGRect] {
        let wanted = Swift.max(1, count)
        let aspect = Double(rect.width / Swift.max(rect.height, 1))
        let columns = Swift.max(1, Int((Double(wanted) * aspect).squareRoot().rounded()))
        let rows = Swift.max(1, Int((Double(wanted) / Double(columns)).rounded(.up)))
        let width = rect.width / CGFloat(columns)
        let height = rect.height / CGFloat(rows)
        var cells: [CGRect] = []
        cells.reserveCapacity(rows * columns)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                cells.append(CGRect(x: rect.minX + CGFloat(column) * width,
                                    y: rect.minY + CGFloat(row) * height,
                                    width: width, height: height))
            }
        }
        return cells
    }

    /// Splits a lot in two along its long side: `share` of it, then the rest.
    func split(_ rect: CGRect, share: CGFloat) -> (CGRect, CGRect) {
        if rect.width >= rect.height {
            let first = rect.width * share
            return (CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height),
                    CGRect(x: rect.minX + first, y: rect.minY, width: rect.width - first,
                           height: rect.height))
        }
        let first = rect.height * share
        return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first),
                CGRect(x: rect.minX, y: rect.minY + first, width: rect.width,
                       height: rect.height - first))
    }

    // MARK: Districts

    /// Code: glass towers on a paved plaza, a helipad on the tallest.
    mutating func techCampus() {
        let u = unit
        let center = CGPoint(x: lot.midX, y: lot.midY)
        line(CGPoint(x: lot.minX, y: center.y), CGPoint(x: lot.maxX, y: center.y),
             Scenery.path, width: Swift.max(1, u * 0.3))
        line(CGPoint(x: center.x, y: lot.minY), CGPoint(x: center.x, y: lot.maxY),
             Scenery.path, width: Swift.max(1, u * 0.3))

        let glassRoof = blend(roof, toward: CGColor(gray: 1, alpha: 1), by: 0.2)
        let cells = grid(lot.insetBy(dx: u * 0.3, dy: u * 0.3), count: count(perUnits: 16, max: 9))
        var tallest: (rect: CGRect, height: CGFloat)?
        for cell in cells {
            let margin = Swift.min(cell.width, cell.height) * rng.between(0.12, 0.24)
            let space = cell.insetBy(dx: margin, dy: margin)
            guard space.width > 4, space.height > 6 else { continue }
            let height = Swift.min(space.height * 0.6, u * rng.between(1.4, 4.2))
            building(in: space, height: height, roof: glassRoof, wall: wall,
                     windows: Scenery.glassWindow)
            if height > (tallest?.height ?? 0) { tallest = (space, height) }
        }
        if let tallest {
            let top = CGRect(x: tallest.rect.minX, y: tallest.rect.minY,
                             width: tallest.rect.width, height: tallest.rect.height - tallest.height)
            let pad = Swift.min(top.width, top.height) * 0.6
            if pad >= 7 {
                let helipad = CGRect(x: top.midX - pad / 2, y: top.midY - pad / 2, width: pad, height: pad)
                ring(helipad, Scenery.chalk, width: 1)
                line(CGPoint(x: helipad.midX - pad * 0.18, y: helipad.midY - pad * 0.22),
                     CGPoint(x: helipad.midX - pad * 0.18, y: helipad.midY + pad * 0.22),
                     Scenery.chalk, width: 1)
                line(CGPoint(x: helipad.midX + pad * 0.18, y: helipad.midY - pad * 0.22),
                     CGPoint(x: helipad.midX + pad * 0.18, y: helipad.midY + pad * 0.22),
                     Scenery.chalk, width: 1)
                line(CGPoint(x: helipad.midX - pad * 0.18, y: helipad.midY),
                     CGPoint(x: helipad.midX + pad * 0.18, y: helipad.midY),
                     Scenery.chalk, width: 1)
            }
        }
    }

    /// Data: rows of low server halls with cooling units on the roofs.
    mutating func dataCenter() {
        let u = unit
        let cells = grid(lot.insetBy(dx: u * 0.4, dy: u * 0.4), count: count(perUnits: 12, max: 12))
        let unitColour = blend(wall, toward: CGColor(gray: 0, alpha: 1), by: 0.35)
        for cell in cells {
            let space = cell.insetBy(dx: cell.width * 0.08, dy: cell.height * 0.12)
            guard space.width > 5, space.height > 5 else { continue }
            let height = u * 0.6
            building(in: space, height: height, roof: roof, wall: wall)
            let top = CGRect(x: space.minX, y: space.minY, width: space.width,
                             height: space.height - Swift.min(height, space.height * 0.6))
            let fan = Swift.min(top.height * 0.45, u * 0.7)
            guard fan >= 2 else { continue }
            var x = top.minX + fan * 0.5
            while x + fan < top.maxX - fan * 0.3 {
                let box = CGRect(x: x, y: top.midY - fan / 2, width: fan, height: fan)
                fill(box, unitColour)
                ring(box.insetBy(dx: fan * 0.18, dy: fan * 0.18), CGColor(gray: 0.85, alpha: 0.35),
                     width: 0.75)
                x += fan * 1.5
            }
        }
        context.setStrokeColor(CGColor(gray: 0.75, alpha: 0.35))
        context.setLineWidth(0.75)
        context.setLineDash(phase: 0, lengths: [2, 1.5])
        context.stroke(lot.insetBy(dx: u * 0.2, dy: u * 0.2))
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Documents: a school — a U-shaped building, a sports field with a running
    /// track, a flagpole, trees.
    mutating func school() {
        let u = unit
        let (campus, grounds) = split(lot, share: rng.between(0.45, 0.58))

        // The U: a main hall along the back, a wing down each side.
        let inner = campus.insetBy(dx: u * 0.4, dy: u * 0.4)
        let thickness = Swift.min(inner.width, inner.height) * 0.32
        let height = u * 1.1
        let brick = blend(wall, toward: CGColor(srgbRed: 0.55, green: 0.25, blue: 0.20, alpha: 1), by: 0.5)
        building(in: CGRect(x: inner.minX, y: inner.minY, width: thickness, height: inner.height),
                 height: height, roof: roof, wall: brick, windows: Scenery.litWindow)
        building(in: CGRect(x: inner.maxX - thickness, y: inner.minY, width: thickness,
                            height: inner.height),
                 height: height, roof: roof, wall: brick, windows: Scenery.litWindow)
        building(in: CGRect(x: inner.minX, y: inner.minY, width: inner.width,
                            height: Swift.min(inner.height, thickness + height)),
                 height: height, roof: roof, wall: brick, windows: Scenery.litWindow)

        // The field, with a running track round it.
        let field = grounds.insetBy(dx: u * 0.5, dy: u * 0.5)
        if field.width > 10, field.height > 8 {
            fill(field, Scenery.turf)
            let track = field.insetBy(dx: field.width * 0.1, dy: field.height * 0.14)
            let bend = Swift.min(track.width, track.height) / 2
            context.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.38, blue: 0.30, alpha: 0.9))
            context.setLineWidth(Swift.max(1, u * 0.3))
            context.addPath(CGPath(roundedRect: track, cornerWidth: bend, cornerHeight: bend,
                                   transform: nil))
            context.strokePath()
            line(CGPoint(x: track.midX, y: track.minY + 2), CGPoint(x: track.midX, y: track.maxY - 2),
                 Scenery.chalk, width: 0.75)

            // Flagpole on the corner of the field nearest the building.
            let base = CGPoint(x: field.minX + u * 0.5, y: field.maxY - u * 0.3)
            line(base, CGPoint(x: base.x, y: base.y - u * 2), CGColor(gray: 0.85, alpha: 1), width: 0.75)
            fill(CGRect(x: base.x, y: base.y - u * 2, width: u * 0.9, height: u * 0.55), Scenery.flag)
        }
        scatterTrees(count(perUnits: 40, max: 8, min: 0), in: grounds, size: u)
    }

    /// Media: a stadium bowl, floodlights at the corners.
    mutating func stadium() {
        let u = unit
        let bowl = lot.insetBy(dx: lot.width * 0.06, dy: lot.height * 0.08)
        oval(bowl.offsetBy(dx: u * 0.4, dy: u * 0.4), Scenery.shadow)
        oval(bowl, wall)
        oval(bowl.insetBy(dx: bowl.width * 0.05, dy: bowl.height * 0.05), roof)
        // Seating tiers.
        ring(bowl.insetBy(dx: bowl.width * 0.11, dy: bowl.height * 0.11),
             CGColor(gray: 0, alpha: 0.25), width: Swift.max(0.75, u * 0.15))
        let pitch = bowl.insetBy(dx: bowl.width * 0.22, dy: bowl.height * 0.24)
        fill(pitch, Scenery.turf)
        context.setStrokeColor(Scenery.chalk)
        context.setLineWidth(0.75)
        context.stroke(pitch.insetBy(dx: 1, dy: 1))
        line(CGPoint(x: pitch.midX, y: pitch.minY + 1), CGPoint(x: pitch.midX, y: pitch.maxY - 1),
             Scenery.chalk, width: 0.75)
        let circle = Swift.min(pitch.width, pitch.height) * 0.3
        ring(CGRect(x: pitch.midX - circle / 2, y: pitch.midY - circle / 2, width: circle, height: circle),
             Scenery.chalk, width: 0.75)

        let mast = Swift.max(2, u * 0.4)
        for corner in [CGPoint(x: lot.minX + mast, y: lot.minY + mast),
                       CGPoint(x: lot.maxX - mast * 2, y: lot.minY + mast),
                       CGPoint(x: lot.minX + mast, y: lot.maxY - mast * 2),
                       CGPoint(x: lot.maxX - mast * 2, y: lot.maxY - mast * 2)] {
            oval(CGRect(x: corner.x - mast, y: corner.y - mast, width: mast * 3, height: mast * 3),
                 Scenery.floodlight)
            fill(CGRect(x: corner.x, y: corner.y, width: mast, height: mast), Scenery.concrete)
        }
    }

    /// Images: a park — a pond, a winding path, a pavilion, lots of trees.
    mutating func park() {
        let u = unit
        let pond = CGRect(x: rng.between(lot.minX, lot.midX), y: rng.between(lot.minY, lot.midY),
                          width: lot.width * rng.between(0.3, 0.45), height: lot.height * rng.between(0.25, 0.4))
        oval(pond.insetBy(dx: -1.5, dy: -1.5), Scenery.path)
        oval(pond, Scenery.water)
        oval(CGRect(x: pond.minX + pond.width * 0.2, y: pond.minY + pond.height * 0.2,
                    width: pond.width * 0.3, height: pond.height * 0.15), CGColor(gray: 1, alpha: 0.12))

        context.setStrokeColor(Scenery.path)
        context.setLineWidth(Swift.max(1, u * 0.35))
        context.move(to: CGPoint(x: lot.minX, y: lot.maxY - lot.height * 0.2))
        context.addCurve(to: CGPoint(x: lot.maxX, y: lot.minY + lot.height * 0.25),
                         control1: CGPoint(x: lot.minX + lot.width * 0.4, y: lot.maxY),
                         control2: CGPoint(x: lot.maxX - lot.width * 0.4, y: lot.minY))
        context.strokePath()

        let side = Swift.min(lot.width, lot.height) * 0.28
        if side > 6 {
            let pavilion = CGRect(x: lot.maxX - side * 1.3, y: lot.maxY - side * 1.3,
                                  width: side, height: side)
            building(in: pavilion, height: u * 0.7, roof: roof, wall: wall)
        }
        scatterTrees(count(perUnits: 6, max: 40, min: 3), in: lot, size: u * 1.2)
    }

    /// Archives: long sheds with ridged roofs and a container yard.
    mutating func warehouse() {
        let u = unit
        let (sheds, yard) = split(lot, share: rng.between(0.55, 0.7))
        let wide = sheds.width >= sheds.height
        let count = Swift.max(1, Swift.min(4, Int((wide ? sheds.width : sheds.height) / (u * 4))))
        for index in 0 ..< count {
            let slice: CGRect = wide
                ? CGRect(x: sheds.minX + sheds.width * CGFloat(index) / CGFloat(count), y: sheds.minY,
                         width: sheds.width / CGFloat(count), height: sheds.height)
                : CGRect(x: sheds.minX, y: sheds.minY + sheds.height * CGFloat(index) / CGFloat(count),
                         width: sheds.width, height: sheds.height / CGFloat(count))
            let space = slice.insetBy(dx: Swift.max(1, u * 0.3), dy: Swift.max(1, u * 0.3))
            guard space.width > 4, space.height > 4 else { continue }
            let height = u * 0.8
            building(in: space, height: height, roof: roof, wall: wall)
            // Corrugated roof.
            let top = CGRect(x: space.minX, y: space.minY, width: space.width,
                             height: space.height - Swift.min(height, space.height * 0.6))
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
            context.setLineWidth(0.6)
            var x = top.minX + 1.5
            while x < top.maxX {
                context.move(to: CGPoint(x: x, y: top.minY))
                context.addLine(to: CGPoint(x: x, y: top.maxY))
                x += 2
            }
            context.strokePath()
        }

        let crate = CGSize(width: u * 1.4, height: u * 0.6)
        guard crate.width > 2 else { return }
        var y = yard.minY + u * 0.4
        while y + crate.height < yard.maxY - u * 0.2 {
            var x = yard.minX + u * 0.4
            while x + crate.width < yard.maxX - u * 0.2 {
                if rng.chance(0.8) {
                    let colour = rng.chance(0.3) ? roof : rng.pick(Scenery.debris)
                    fill(CGRect(x: x, y: y, width: crate.width, height: crate.height),
                         blend(colour, toward: CGColor(gray: 0, alpha: 1), by: 0.25))
                }
                x += crate.width + u * 0.25
            }
            y += crate.height + u * 0.35
        }
    }

    /// Apps: a plant with a sawtooth roof and smoking chimneys.
    mutating func factory() {
        let u = unit
        let plant = lot.insetBy(dx: lot.width * 0.1, dy: lot.height * 0.1)
        let height = u * 1.2
        building(in: plant, height: height, roof: roof, wall: wall, windows: Scenery.litWindow)
        let top = CGRect(x: plant.minX, y: plant.minY, width: plant.width,
                         height: plant.height - Swift.min(height, plant.height * 0.6))
        let tooth = Swift.max(3, u * 0.9)
        var x = top.minX
        while x < top.maxX {
            fill(CGRect(x: x, y: top.minY, width: tooth * 0.4, height: top.height),
                 CGColor(gray: 0, alpha: 0.2))
            x += tooth
        }

        let chimneys = count(perUnits: 30, max: 4)
        for index in 0 ..< chimneys {
            let width = Swift.max(2, u * 0.55)
            let cx = plant.minX + plant.width * CGFloat(index + 1) / CGFloat(chimneys + 1)
            let stack = CGRect(x: cx - width / 2, y: top.minY + top.height * 0.25,
                               width: width, height: top.height * 0.5)
            let rise = u * rng.between(2, 3.2)
            building(in: CGRect(x: stack.minX, y: stack.minY - rise, width: stack.width,
                                height: stack.height + rise),
                     height: rise, roof: Scenery.concrete, wall: wall)
            fill(CGRect(x: stack.minX, y: stack.minY - rise + width * 1.2, width: width, height: width * 0.5),
                 Scenery.flag)
            var puff = CGPoint(x: stack.midX, y: stack.minY - rise)
            var size = width * 1.2
            for _ in 0 ..< 4 {
                oval(CGRect(x: puff.x - size / 2, y: puff.y - size / 2, width: size, height: size),
                     Scenery.smoke)
                puff.x += size * 0.6
                puff.y -= size * 0.45
                size *= 1.3
            }
        }
    }

    /// System files: round storage tanks joined by pipes.
    mutating func utility() {
        let u = unit
        let cells = grid(lot.insetBy(dx: u * 0.3, dy: u * 0.3), count: count(perUnits: 12, max: 9))
        var tanks: [(center: CGPoint, diameter: CGFloat)] = []
        for cell in cells {
            let diameter = Swift.min(cell.width, cell.height) * rng.between(0.5, 0.75)
            guard diameter > 4 else { continue }
            tanks.append((CGPoint(x: cell.midX, y: cell.midY), diameter))
        }
        for (a, b) in zip(tanks, tanks.dropFirst()) {
            line(a.center, b.center, Scenery.concrete, width: Swift.max(1, u * 0.2))
        }
        for (center, diameter) in tanks {
            let tank = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                              width: diameter, height: diameter)
            oval(tank.offsetBy(dx: diameter * 0.12, dy: diameter * 0.12), Scenery.shadow)
            oval(tank, wall)
            oval(tank.insetBy(dx: diameter * 0.06, dy: diameter * 0.06), roof)
            ring(tank.insetBy(dx: diameter * 0.22, dy: diameter * 0.22), CGColor(gray: 0, alpha: 0.2),
                 width: 0.75)
            oval(CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2), wall)
        }
    }

    /// Everything else: a neighbourhood of small houses and gardens.
    mutating func housing() {
        let u = unit
        let cells = grid(lot.insetBy(dx: u * 0.2, dy: u * 0.2), count: count(perUnits: 5, max: 36))
        for cell in cells {
            if rng.chance(0.18) {
                tree(at: CGPoint(x: cell.midX, y: cell.midY),
                     radius: Swift.min(cell.width, cell.height) * 0.3)
                continue
            }
            let house = CGRect(x: cell.minX + cell.width * rng.between(0.12, 0.22),
                               y: cell.minY + cell.height * rng.between(0.12, 0.22),
                               width: cell.width * rng.between(0.55, 0.7),
                               height: cell.height * rng.between(0.55, 0.7))
            guard house.width > 3, house.height > 3 else { continue }
            let height = Swift.min(house.height * 0.4, u * 0.5)
            building(in: house, height: height, roof: roof, wall: wall)
            // Gable: the far half of the roof in shade.
            let top = CGRect(x: house.minX, y: house.minY, width: house.width, height: house.height - height)
            fill(CGRect(x: top.midX, y: top.minY, width: top.width / 2, height: top.height),
                 CGColor(gray: 0, alpha: 0.22))
        }
    }

    /// Rebuildable things: mounds of rubbish, debris, a bulldozer, gulls, a fence.
    mutating func landfill() {
        let u = unit
        // Mounds, piled from the widest and darkest up.
        let mounds = count(perUnits: 30, max: 5)
        for _ in 0 ..< mounds {
            var heap = CGRect(x: rng.between(lot.minX - u, lot.maxX - u * 4),
                              y: rng.between(lot.minY - u, lot.maxY - u * 3),
                              width: Swift.max(u * 4, lot.width * rng.between(0.35, 0.65)),
                              height: Swift.max(u * 3, lot.height * rng.between(0.3, 0.55)))
            for layer in 1 ..< Scenery.dirt.count {
                oval(heap, Scenery.dirt[layer])
                heap = heap.insetBy(dx: heap.width * 0.16, dy: heap.height * 0.18)
                    .offsetBy(dx: -heap.width * 0.04, dy: -heap.height * 0.06)
            }
        }

        // Debris.
        let specks = Swift.max(12, Swift.min(240, Int(area / 28)))
        for _ in 0 ..< specks {
            let size = rng.between(0.8, Swift.max(1.2, u * 0.35))
            fill(CGRect(x: rng.between(lot.minX, lot.maxX), y: rng.between(lot.minY, lot.maxY),
                        width: size * rng.between(0.8, 1.8), height: size),
                 rng.chance(0.15) ? roof : rng.pick(Scenery.debris))
        }
        // Old tyres.
        for _ in 0 ..< count(perUnits: 20, max: 8, min: 0) {
            let size = u * rng.between(0.5, 0.8)
            ring(CGRect(x: rng.between(lot.minX, lot.maxX - size), y: rng.between(lot.minY, lot.maxY - size),
                        width: size, height: size), Scenery.rubber, width: Swift.max(0.75, size * 0.25))
        }

        // A bulldozer pushing the pile.
        if lot.width > u * 5, lot.height > u * 4 {
            let body = CGRect(x: rng.between(lot.minX + u, lot.maxX - u * 3),
                              y: rng.between(lot.minY + u * 1.5, lot.maxY - u * 2),
                              width: u * 1.8, height: u * 1.1)
            fill(body.offsetBy(dx: u * 0.25, dy: u * 0.25), Scenery.shadow)
            fill(CGRect(x: body.minX, y: body.maxY - u * 0.3, width: body.width, height: u * 0.3), Scenery.rubber)
            fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height - u * 0.3),
                 Scenery.caution)
            fill(CGRect(x: body.minX + body.width * 0.45, y: body.minY - u * 0.45,
                        width: body.width * 0.4, height: u * 0.55), Scenery.caution)
            fill(CGRect(x: body.minX - u * 0.35, y: body.minY + u * 0.1, width: u * 0.25,
                        height: body.height - u * 0.1), Scenery.concrete)
        }

        // Gulls.
        context.setStrokeColor(CGColor(gray: 0.95, alpha: 0.85))
        context.setLineWidth(0.75)
        for _ in 0 ..< count(perUnits: 25, max: 6, min: 0) {
            let at = CGPoint(x: rng.between(lot.minX + 3, lot.maxX - 3), y: rng.between(lot.minY + 3, lot.maxY - 3))
            let span = u * 0.4
            context.move(to: CGPoint(x: at.x - span, y: at.y - span * 0.4))
            context.addLine(to: at)
            context.addLine(to: CGPoint(x: at.x + span, y: at.y - span * 0.4))
        }
        context.strokePath()

        // Chain-link fence.
        context.setStrokeColor(CGColor(gray: 0.8, alpha: 0.45))
        context.setLineWidth(0.75)
        context.setLineDash(phase: 0, lengths: [1.5, 1.5])
        context.stroke(lot.insetBy(dx: 1.5, dy: 1.5))
        context.setLineDash(phase: 0, lengths: [])
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func blend(_ colour: CGColor, toward other: CGColor, by fraction: CGFloat) -> CGColor {
        guard let a = colour.converted(to: Painter.sRGB, intent: .defaultIntent, options: nil)?.components,
              let b = other.converted(to: Painter.sRGB, intent: .defaultIntent, options: nil)?.components,
              a.count >= 3, b.count >= 3 else { return colour }
        return CGColor(srgbRed: a[0] + (b[0] - a[0]) * fraction,
                       green: a[1] + (b[1] - a[1]) * fraction,
                       blue: a[2] + (b[2] - a[2]) * fraction,
                       alpha: colour.alpha)
    }
}

private extension SplitMix64 {
    /// Roughly two windows in three are lit.
    mutating func unitIsLit() -> Bool { unit() < 0.66 }
}
