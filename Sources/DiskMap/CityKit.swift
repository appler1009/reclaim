import AppKit
import ReclaimKit
import SceneKit

/// Builds one block of the 3D town from SceneKit primitives.
///
/// Works in layout points, like the flat map, and converts on the way into
/// the scene, so a block's footprint is exactly its tile. Everything is placed
/// by a generator seeded from the item's name: the same folder is always the
/// same block. Primitive counts are capped, so a huge block costs about what
/// a large one does.
struct Kit {
    let lot: CityLot
    let materials: MaterialCache
    var rng: SplitMix64
    let root = SCNNode()
    /// Height of the tallest thing built, in world units.
    private(set) var tallest: CGFloat = 0.03

    init(lot: CityLot, materials: MaterialCache, rng: SplitMix64) {
        self.lot = lot
        self.materials = materials
        self.rng = rng
        let street = min(3, max(0.75, min(lot.rect.width, lot.rect.height) * 0.05))
        block = lot.rect.insetBy(dx: street, dy: street)
        ground = block.insetBy(dx: min(2, block.width * 0.1), dy: min(2, block.height * 0.1))
        let colour = lot.family.color
        roofColour = colour.cgColor
        wallColour = (colour.blended(withFraction: 0.5, of: .black) ?? colour).cgColor
    }

    private let block: CGRect
    /// The part of the block inside the sidewalk, where things are built.
    private let ground: CGRect
    private let roofColour: CGColor
    private let wallColour: CGColor

    private var unit: CGFloat { min(14, max(3, (ground.width * ground.height).squareRoot() / 10)) }
    private var area: CGFloat { ground.width * ground.height }
    private var district: District { lot.district }
    private var roof: SCNMaterial { materials.paint(roofColour) }
    private var wall: SCNMaterial { materials.paint(wallColour) }

    func count(perUnits squareUnits: CGFloat, max ceiling: Int, min floor: Int = 1) -> Int {
        let fits = Int(area / (unit * unit * squareUnits))
        return Swift.max(floor, Swift.min(ceiling, fits))
    }

    // MARK: - Entry

    mutating func build() {
        // Sidewalk and ground: thin slabs, so blocks read as raised kerbs.
        slab(block, height: 0.6, material: materials.paint(Shade.sidewalk))
        slab(ground, from: 0.6, height: 0.4,
             material: materials.paint(CityBlock.ground(district), rough: 1))

        guard ground.width >= 10, ground.height >= 10 else {
            // Too small to build on: one low box in the block's colour.
            let pad = min(ground.width, ground.height) * 0.15
            box(ground.insetBy(dx: pad, dy: pad), from: 1, height: max(2, unit * 0.8),
                top: district.isGarbage ? materials.paint(Shade.dirt) : roof, side: wall)
            return
        }

        switch district.archetype {
        case .towers: towers()
        case .halls: halls()
        case .campus: campus()
        case .arena: arena()
        case .green: green()
        case .sheds: sheds()
        case .plant: plant()
        case .tanks: tanks()
        case .housing: housing()
        case .airport: airport()
        case .mounds: mounds()
        case .scrap: scrap()
        case .shacks: shacks()
        case .toxic: toxic()
        case .logs: logs()
        }
    }

    // MARK: - Primitives (layout points in, world units out)

    private static let s = CitySceneView.scale

    private mutating func add(_ geometry: SCNGeometry, at x: CGFloat, _ z: CGFloat, y: CGFloat,
                              scale: SCNVector3, euler: SCNVector3 = SCNVector3Zero, top: CGFloat) {
        let node = SCNNode(geometry: geometry)
        node.position = CityBuilder.world(x, z, y: y * Kit.s)
        node.scale = scale
        node.eulerAngles = euler
        root.addChildNode(node)
        tallest = Swift.max(tallest, top * Kit.s)
    }

    /// A box standing on `from`, `height` tall, footprint `rect`.
    mutating func box(_ rect: CGRect, from base: CGFloat = 1, height: CGFloat,
                      top: SCNMaterial, side: SCNMaterial, yaw: CGFloat = 0) {
        guard rect.width > 0.2, rect.height > 0.2, height > 0 else { return }
        add(materials.unitBox(top: top, side: side), at: rect.midX, rect.midY, y: base + height / 2,
            scale: SCNVector3(rect.width * Kit.s, height * Kit.s, rect.height * Kit.s),
            euler: SCNVector3(0, yaw, 0), top: base + height)
    }

    /// A flat slab: paving, a pitch, a pond's water.
    mutating func slab(_ rect: CGRect, from base: CGFloat = 0, height: CGFloat = 0.3, material: SCNMaterial) {
        box(rect, from: base, height: height, top: material, side: material)
    }

    mutating func cylinder(_ center: CGPoint, radius: CGFloat, from base: CGFloat = 1, height: CGFloat,
                           material: SCNMaterial, squash: CGFloat = 1) {
        guard radius > 0.1, height > 0 else { return }
        add(materials.unitCylinder(material), at: center.x, center.y, y: base + height / 2,
            scale: SCNVector3(radius * 2 * Kit.s, height * Kit.s, radius * 2 * squash * Kit.s),
            top: base + height)
    }

    /// A cylinder lying on its side along x (`alongX`) or z, like a log or a pipe.
    mutating func lying(_ center: CGPoint, radius: CGFloat, length: CGFloat, base: CGFloat,
                        alongX: Bool, material: SCNMaterial) {
        guard radius > 0.1, length > 0 else { return }
        add(materials.unitCylinder(material), at: center.x, center.y, y: base + radius,
            scale: SCNVector3(radius * 2 * Kit.s, length * Kit.s, radius * 2 * Kit.s),
            euler: alongX ? SCNVector3(0, 0, CGFloat.pi / 2) : SCNVector3(CGFloat.pi / 2, 0, 0),
            top: base + radius * 2)
    }

    mutating func sphere(_ center: CGPoint, radius: CGFloat, y: CGFloat, material: SCNMaterial,
                         squash: CGFloat = 1, stretch: CGPoint = CGPoint(x: 1, y: 1)) {
        guard radius > 0.1 else { return }
        add(materials.unitSphere(material), at: center.x, center.y, y: y,
            scale: SCNVector3(radius * 2 * stretch.x * Kit.s, radius * 2 * squash * Kit.s,
                              radius * 2 * stretch.y * Kit.s),
            top: y + radius * squash)
    }

    mutating func cone(_ center: CGPoint, radius: CGFloat, from base: CGFloat, height: CGFloat,
                       material: SCNMaterial) {
        guard radius > 0.1, height > 0 else { return }
        add(materials.unitCone(material), at: center.x, center.y, y: base + height / 2,
            scale: SCNVector3(radius * 2 * Kit.s, height * Kit.s, radius * 2 * Kit.s), top: base + height)
    }

    /// A hipped roof over `rect`.
    mutating func pyramid(_ rect: CGRect, from base: CGFloat, height: CGFloat, material: SCNMaterial) {
        guard rect.width > 0.2, rect.height > 0.2, height > 0 else { return }
        // SCNPyramid's origin is the middle of its base.
        add(materials.unitPyramid(material), at: rect.midX, rect.midY, y: base,
            scale: SCNVector3(rect.width * Kit.s, height * Kit.s, rect.height * Kit.s), top: base + height)
    }

    /// An oval ring lying flat: a running track, a stadium's stands.
    mutating func ring(_ rect: CGRect, from base: CGFloat, height: CGFloat, thickness: CGFloat,
                       material: SCNMaterial) {
        guard rect.width > 1, rect.height > 1 else { return }
        let inner = Swift.max(0.05, 0.5 - thickness / Swift.max(rect.width, rect.height))
        add(materials.unitTube(material, inner: inner), at: rect.midX, rect.midY, y: base + height / 2,
            scale: SCNVector3(rect.width * Kit.s, height * Kit.s, rect.height * Kit.s), top: base + height)
    }

    mutating func tree(_ at: CGPoint, size: CGFloat, dead: Bool = false) {
        let trunk = materials.paint(Shade.bark)
        let height = size * rng.between(1.4, 2.2)
        cylinder(at, radius: Swift.max(0.3, size * 0.12), height: height * 0.45, material: trunk)
        if dead {
            add(materials.unitCylinder(trunk), at: at.x + size * 0.2, at.y, y: 1 + height * 0.55,
                scale: SCNVector3(0.3 * Kit.s, height * 0.5 * Kit.s, 0.3 * Kit.s),
                euler: SCNVector3(0, 0, -0.6), top: 1 + height * 0.8)
            return
        }
        let leaves = materials.paint(rng.pick(Shade.foliage))
        if rng.chance(0.35) {
            cone(at, radius: size * 0.55, from: 1 + height * 0.3, height: height * 0.9, material: leaves)
        } else {
            sphere(at, radius: size * 0.6, y: 1 + height * 0.6, material: leaves, squash: 0.9)
        }
    }

    func grid(_ rect: CGRect, count: Int) -> [CGRect] {
        let wanted = Swift.max(1, count)
        let aspect = Double(rect.width / Swift.max(rect.height, 1))
        let columns = Swift.max(1, Int((Double(wanted) * aspect).squareRoot().rounded()))
        let rows = Swift.max(1, Int((Double(wanted) / Double(columns)).rounded(.up)))
        let width = rect.width / CGFloat(columns)
        let height = rect.height / CGFloat(rows)
        var cells: [CGRect] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                cells.append(CGRect(x: rect.minX + CGFloat(column) * width,
                                    y: rect.minY + CGFloat(row) * height, width: width, height: height))
            }
        }
        return cells
    }

    func split(_ rect: CGRect, share: CGFloat) -> (CGRect, CGRect) {
        if rect.width >= rect.height {
            let first = rect.width * share
            return (CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height),
                    CGRect(x: rect.minX + first, y: rect.minY, width: rect.width - first, height: rect.height))
        }
        let first = rect.height * share
        return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first),
                CGRect(x: rect.minX, y: rect.minY + first, width: rect.width, height: rect.height - first))
    }

    private mutating func spot(in rect: CGRect, margin: CGFloat = 0) -> CGPoint {
        CGPoint(x: rng.between(rect.minX + margin, Swift.max(rect.minX + margin, rect.maxX - margin)),
                y: rng.between(rect.minY + margin, Swift.max(rect.minY + margin, rect.maxY - margin)))
    }

    // MARK: - Archetypes

    /// Code and downtown: towers with lit windows. A tech campus gets a
    /// helipad, an AI lab a glowing dome, the exchange a radio mast.
    private mutating func towers() {
        let u = unit
        let lift = CGFloat(district.heightScale)
        let glass = materials.paint(roofColour, rough: 0.25, metal: 0.4, windows: true)
        let cells = grid(ground.insetBy(dx: u * 0.3, dy: u * 0.3),
                         count: count(perUnits: district == .apartments ? 10 : 16, max: 12))
        var top: (rect: CGRect, height: CGFloat)?
        for cell in cells {
            let margin = Swift.min(cell.width, cell.height) * rng.between(0.12, 0.24)
            let footprint = cell.insetBy(dx: margin, dy: margin)
            guard footprint.width > 2, footprint.height > 2 else { continue }
            let height = u * rng.between(2.2, 6.5) * lift
            box(footprint, height: height, top: roof, side: glass)
            // Downtown steps back as it rises.
            if district == .downtown, rng.chance(0.6) {
                let upper = footprint.insetBy(dx: footprint.width * 0.2, dy: footprint.height * 0.2)
                box(upper, from: 1 + height, height: height * 0.4, top: roof, side: glass)
            }
            if height > (top?.height ?? 0) { top = (footprint, height) }
        }
        guard let top else { return }
        let peak = 1 + top.height
        let center = CGPoint(x: top.rect.midX, y: top.rect.midY)
        switch district {
        case .techCampus:
            cylinder(center, radius: Swift.min(top.rect.width, top.rect.height) * 0.3, from: peak, height: 0.3,
                     material: materials.paint(Shade.chalk))
        case .aiLab:
            sphere(center, radius: Swift.min(top.rect.width, top.rect.height) * 0.38, y: peak,
                   material: materials.paint(Shade.cyan, rough: 0.2, glow: 0.6))
        case .telephoneExchange:
            cylinder(center, radius: 0.5, from: peak, height: u * 4, material: materials.paint(Shade.chalk))
            sphere(CGPoint(x: center.x, y: center.y), radius: u * 0.5, y: peak + u * 3,
                   material: materials.paint(Shade.chalk), squash: 0.4)
        default:
            cylinder(center, radius: 0.4, from: peak, height: u * 1.2, material: materials.paint(Shade.concrete))
        }
    }

    /// Civic buildings: a broad hall, with columns and a pediment or a dome
    /// for the grand ones, rooftop plant for the data centre.
    private mutating func halls() {
        let u = unit
        let stone = materials.paint(Shade.stone)
        let cells = grid(ground.insetBy(dx: u * 0.4, dy: u * 0.4),
                         count: district == .dataCenter ? count(perUnits: 14, max: 8) : 1)
        for cell in cells {
            let hall = cell.insetBy(dx: cell.width * 0.1, dy: cell.height * 0.14)
            guard hall.width > 3, hall.height > 3 else { continue }
            let height = u * (district == .dataCenter ? 1 : 1.6)
            let side = district == .dataCenter || district == .printShop ? wall : stone
            box(hall, height: height, top: roof, side: side)
            let peak = 1 + height

            switch district {
            case .dataCenter:
                // Cooling units in a row along the roof.
                let fan = Swift.min(hall.height * 0.3, u * 0.8)
                var x = hall.minX + fan
                while x < hall.maxX - fan {
                    cylinder(CGPoint(x: x, y: hall.midY), radius: fan * 0.45, from: peak, height: fan * 0.4,
                             material: materials.paint(Shade.concrete))
                    x += fan * 1.6
                }
            case .cityHall, .recordsHall, .embassy:
                sphere(CGPoint(x: hall.midX, y: hall.midY), radius: Swift.min(hall.width, hall.height) * 0.3,
                       y: peak, material: district == .cityHall ? materials.paint(Shade.gold, rough: 0.3, metal: 0.8)
                                                               : roof)
                columns(along: hall, height: height)
                if district == .embassy { flags(at: CGPoint(x: hall.minX, y: hall.maxY + u), count: 3) }
            case .museum, .publicLibrary, .bankVault:
                pyramid(hall.insetBy(dx: 0, dy: hall.height * 0.2), from: peak, height: u * 0.9, material: roof)
                columns(along: hall, height: height)
            case .postOffice:
                flags(at: CGPoint(x: hall.maxX - u, y: hall.maxY + u * 0.6), count: 1)
            case .printShop:
                sawtooth(on: hall, from: peak)
            default:
                break
            }
        }
    }

    private mutating func columns(along hall: CGRect, height: CGFloat) {
        let u = unit
        let stone = materials.paint(Shade.stone)
        let count = Swift.max(3, Swift.min(10, Int(hall.width / (u * 0.9))))
        for index in 0 ..< count {
            let x = hall.minX + hall.width * (CGFloat(index) + 0.5) / CGFloat(count)
            cylinder(CGPoint(x: x, y: hall.maxY + u * 0.35), radius: u * 0.18, height: height, material: stone)
        }
    }

    private mutating func flags(at base: CGPoint, count: Int) {
        let u = unit
        for index in 0 ..< count {
            let pole = CGPoint(x: base.x + CGFloat(index) * u * 0.8, y: base.y)
            cylinder(pole, radius: 0.25, height: u * 2.4, material: materials.paint(Shade.chalk))
            box(CGRect(x: pole.x, y: pole.y - 0.1, width: u * 0.8, height: 0.2), from: 1 + u * 1.8,
                height: u * 0.5, top: materials.paint(rng.pick(Shade.flagColours)),
                side: materials.paint(rng.pick(Shade.flagColours)))
        }
    }

    private mutating func sawtooth(on hall: CGRect, from base: CGFloat) {
        let u = unit
        let tooth = Swift.max(3, u * 1.2)
        var x = hall.minX
        while x + tooth <= hall.maxX + 0.1 {
            pyramid(CGRect(x: x, y: hall.minY, width: tooth, height: hall.height), from: base,
                    height: u * 0.6, material: roof)
            x += tooth
        }
    }

    /// Documents: a U-shaped school and its playing field; a university adds a
    /// clock tower.
    private mutating func campus() {
        let u = unit
        let (site, grounds) = split(ground, share: rng.between(0.45, 0.58))
        let inner = site.insetBy(dx: u * 0.4, dy: u * 0.4)
        let thickness = Swift.min(inner.width, inner.height) * 0.3
        let height = u * (district == .university ? 1.8 : 1.2)
        let brick = materials.paint(Shade.brick)
        box(CGRect(x: inner.minX, y: inner.minY, width: thickness, height: inner.height),
            height: height, top: roof, side: brick)
        box(CGRect(x: inner.maxX - thickness, y: inner.minY, width: thickness, height: inner.height),
            height: height, top: roof, side: brick)
        box(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: thickness),
            height: height, top: roof, side: brick)
        if district == .university {
            let tower = CGRect(x: inner.midX - u * 0.7, y: inner.minY, width: u * 1.4, height: u * 1.4)
            box(tower, height: height * 2.2, top: roof, side: brick)
            pyramid(tower, from: 1 + height * 2.2, height: u * 1.4, material: roof)
        }

        let field = grounds.insetBy(dx: u * 0.5, dy: u * 0.5)
        guard field.width > 6, field.height > 6 else { return }
        slab(field, from: 1, height: 0.2, material: materials.paint(Shade.turf))
        ring(field.insetBy(dx: field.width * 0.08, dy: field.height * 0.1), from: 1.2, height: 0.15,
             thickness: Swift.max(1, u * 0.35), material: materials.paint(Shade.track))
        cylinder(CGPoint(x: field.minX + u * 0.4, y: field.maxY - u * 0.4), radius: 0.25, height: u * 2.6,
                 material: materials.paint(Shade.chalk))
        box(CGRect(x: field.minX + u * 0.4, y: field.maxY - u * 0.5, width: u, height: 0.2),
            from: 1 + u * 2, height: u * 0.55, top: materials.paint(Shade.flag), side: materials.paint(Shade.flag))
    }

    /// Media: a stadium bowl under floodlights, or the sails of a concert hall.
    private mutating func arena() {
        let u = unit
        if district == .concertHall {
            let shell = materials.paint(Shade.chalk, rough: 0.4)
            let base = ground.insetBy(dx: ground.width * 0.15, dy: ground.height * 0.2)
            box(base, height: u * 0.6, top: materials.paint(Shade.stone), side: materials.paint(Shade.stone))
            let sails = 3
            for index in 0 ..< sails {
                let x = base.minX + base.width * (CGFloat(index) + 0.5) / CGFloat(sails)
                let radius = Swift.min(base.width / CGFloat(sails), base.height) * rng.between(0.45, 0.6)
                sphere(CGPoint(x: x, y: base.midY), radius: radius, y: 1 + u * 0.6, material: index == 1 ? roof : shell,
                       squash: 1.3, stretch: CGPoint(x: 0.7, y: 1))
            }
            return
        }
        let bowl = ground.insetBy(dx: ground.width * 0.06, dy: ground.height * 0.08)
        let height = u * 1.6
        ring(bowl, from: 1, height: height, thickness: Swift.min(bowl.width, bowl.height) * 0.16, material: roof)
        ring(bowl.insetBy(dx: bowl.width * 0.03, dy: bowl.height * 0.03), from: 1, height: height * 0.4,
             thickness: Swift.min(bowl.width, bowl.height) * 0.22, material: wall)
        slab(bowl.insetBy(dx: bowl.width * 0.22, dy: bowl.height * 0.24), from: 1, height: 0.2,
             material: materials.paint(Shade.turf))
        let light = materials.paint(Shade.lamp, rough: 0.3, glow: 1)
        for corner in [CGPoint(x: bowl.minX, y: bowl.minY), CGPoint(x: bowl.maxX, y: bowl.minY),
                       CGPoint(x: bowl.minX, y: bowl.maxY), CGPoint(x: bowl.maxX, y: bowl.maxY)] {
            cylinder(corner, radius: 0.35, height: height * 1.8, material: materials.paint(Shade.concrete))
            box(CGRect(x: corner.x - u * 0.4, y: corner.y - u * 0.2, width: u * 0.8, height: u * 0.4),
                from: 1 + height * 1.8, height: u * 0.3, top: light, side: light)
        }
    }

    /// Images and fun: a park with a pond and trees; the amusement park adds a
    /// big wheel and a carousel; the art studio, small studios and sculptures.
    private mutating func green() {
        let u = unit
        let pond = CGRect(x: rng.between(ground.minX, ground.midX), y: rng.between(ground.minY, ground.midY),
                          width: ground.width * rng.between(0.25, 0.4), height: ground.height * rng.between(0.2, 0.35))
        cylinder(CGPoint(x: pond.midX, y: pond.midY), radius: pond.width / 2, from: 1, height: 0.25,
                 material: materials.paint(Shade.water, rough: 0.1, metal: 0.2),
                 squash: pond.height / Swift.max(pond.width, 1))

        switch district {
        case .amusementPark:
            let side = Swift.min(ground.width, ground.height)
            let wheel = side * 0.32
            let hub = CGPoint(x: ground.maxX - wheel * 0.9, y: ground.midY)
            add(materials.unitTorus(materials.paint(roofColour, rough: 0.4, glow: 0.4)),
                at: hub.x, hub.y, y: 1 + wheel * 1.1,
                scale: SCNVector3(wheel * 2 * Kit.s, wheel * 2 * Kit.s, wheel * 2 * Kit.s),
                euler: SCNVector3(CGFloat.pi / 2, 0, 0), top: 1 + wheel * 2.1)
            cylinder(hub, radius: 0.4, height: wheel * 1.1, material: materials.paint(Shade.concrete))
            let carousel = CGPoint(x: ground.minX + side * 0.25, y: ground.maxY - side * 0.25)
            cylinder(carousel, radius: side * 0.12, height: u * 0.6, material: materials.paint(Shade.chalk))
            cone(carousel, radius: side * 0.14, from: 1 + u * 0.6, height: u * 0.9, material: roof)
        case .artStudio:
            for _ in 0 ..< count(perUnits: 40, max: 4) {
                let at = spot(in: ground, margin: u * 1.5)
                box(CGRect(x: at.x - u, y: at.y - u * 0.7, width: u * 2, height: u * 1.4), height: u,
                    top: roof, side: materials.paint(Shade.chalk))
            }
            for _ in 0 ..< count(perUnits: 30, max: 5) {
                let at = spot(in: ground, margin: u)
                cylinder(at, radius: u * 0.25, height: u * 0.6, material: materials.paint(Shade.stone))
                sphere(at, radius: u * 0.4, y: 1 + u, material: materials.paint(rng.pick(Shade.flagColours), rough: 0.3,
                                                                                  metal: 0.6))
            }
        default:
            let side = Swift.min(ground.width, ground.height) * 0.22
            if side > 4 {
                let pavilion = CGRect(x: ground.maxX - side * 1.3, y: ground.maxY - side * 1.3,
                                      width: side, height: side)
                box(pavilion, height: u * 0.8, top: roof, side: materials.paint(Shade.chalk))
                pyramid(pavilion, from: 1 + u * 0.8, height: u * 0.6, material: roof)
            }
        }
        for _ in 0 ..< count(perUnits: 7, max: 36, min: 3) {
            tree(spot(in: ground, margin: u * 0.5), size: u * rng.between(0.8, 1.3))
        }
    }

    /// Archives: long sheds with hipped roofs and a container yard; the port
    /// adds gantry cranes; the film studio's sound stages stand taller.
    private mutating func sheds() {
        let u = unit
        let (yard, stacks) = split(ground, share: rng.between(0.55, 0.7))
        let wide = yard.width >= yard.height
        let count = Swift.max(1, Swift.min(4, Int((wide ? yard.width : yard.height) / (u * 4))))
        let height = u * (district == .filmStudio ? 2.2 : 1.1)
        for index in 0 ..< count {
            let share = 1 / CGFloat(count)
            let slice = wide
                ? CGRect(x: yard.minX + yard.width * CGFloat(index) * share, y: yard.minY,
                         width: yard.width * share, height: yard.height)
                : CGRect(x: yard.minX, y: yard.minY + yard.height * CGFloat(index) * share,
                         width: yard.width, height: yard.height * share)
            let shed = slice.insetBy(dx: Swift.max(1, u * 0.35), dy: Swift.max(1, u * 0.35))
            box(shed, height: height, top: roof, side: wall)
            pyramid(shed, from: 1 + height, height: u * 0.6, material: roof)
        }

        let crate = CGSize(width: u * 1.5, height: u * 0.6)
        var y = stacks.minY + u * 0.4
        while y + crate.height < stacks.maxY - u * 0.2 {
            var x = stacks.minX + u * 0.4
            while x + crate.width < stacks.maxX - u * 0.2 {
                let tiers = Int(rng.between(1, district == .containerPort ? 4 : 2.6))
                for tier in 0 ..< tiers {
                    let colour = materials.paint(rng.chance(0.3) ? roofColour : rng.pick(Shade.containers))
                    box(CGRect(x: x, y: y, width: crate.width, height: crate.height),
                        from: 1 + CGFloat(tier) * u * 0.6, height: u * 0.6, top: colour, side: colour)
                }
                x += crate.width + u * 0.25
            }
            y += crate.height + u * 0.35
        }

        if district == .containerPort, stacks.width > u * 3, stacks.height > u * 3 {
            let crane = materials.paint(Shade.caution, rough: 0.5, metal: 0.4)
            let legs = [CGPoint(x: stacks.minX + u * 0.3, y: stacks.midY),
                        CGPoint(x: stacks.maxX - u * 0.3, y: stacks.midY)]
            for leg in legs { cylinder(leg, radius: u * 0.2, height: u * 3.2, material: crane) }
            box(CGRect(x: stacks.minX, y: stacks.midY - u * 0.25, width: stacks.width, height: u * 0.5),
                from: 1 + u * 3.2, height: u * 0.4, top: crane, side: crane)
        }
    }

    /// Apps: a plant with a sawtooth roof and smoking chimneys; the industrial
    /// park is several; a workshop is one small one.
    private mutating func plant() {
        let u = unit
        let plants = district == .industrialPark ? count(perUnits: 30, max: 6) : 1
        let smoke = materials.paint(Shade.smoke, rough: 1)
        for cell in grid(ground.insetBy(dx: u * 0.3, dy: u * 0.3), count: plants) {
            let shed = cell.insetBy(dx: cell.width * 0.1, dy: cell.height * 0.12)
            guard shed.width > 3, shed.height > 3 else { continue }
            let height = u * (district == .workshop ? 0.8 : 1.4)
            box(shed, height: height, top: roof, side: wall)
            sawtooth(on: shed, from: 1 + height)
            let chimneys = district == .workshop ? 1 : Swift.max(1, Swift.min(3, Int(shed.width / (u * 3))))
            for index in 0 ..< chimneys {
                let at = CGPoint(x: shed.minX + shed.width * CGFloat(index + 1) / CGFloat(chimneys + 1),
                                 y: shed.minY + shed.height * 0.3)
                let rise = u * rng.between(3, 4.5) * CGFloat(district.heightScale)
                cylinder(at, radius: u * 0.3, height: rise, material: materials.paint(Shade.concrete))
                cylinder(at, radius: u * 0.32, from: 1 + rise * 0.8, height: u * 0.3, material: materials.paint(Shade.flag))
                var puff = CGPoint(x: at.x, y: at.y)
                var size = u * 0.4
                var lift = 1 + rise + size
                for _ in 0 ..< 3 {
                    sphere(puff, radius: size, y: lift, material: smoke)
                    puff.x += size * 0.7
                    lift += size * 1.1
                    size *= 1.35
                }
            }
        }
    }

    /// System: storage tanks with domed tops joined by pipes, and a cooling tower.
    private mutating func tanks() {
        let u = unit
        let cells = grid(ground.insetBy(dx: u * 0.3, dy: u * 0.3), count: count(perUnits: 14, max: 9))
        var centers: [CGPoint] = []
        for cell in cells {
            let radius = Swift.min(cell.width, cell.height) * rng.between(0.25, 0.36)
            guard radius > 2 else { continue }
            let center = CGPoint(x: cell.midX, y: cell.midY)
            let height = u * rng.between(1, 2)
            cylinder(center, radius: radius, height: height, material: roof)
            sphere(center, radius: radius, y: 1 + height, material: roof, squash: 0.3)
            centers.append(center)
        }
        let pipe = materials.paint(Shade.concrete, rough: 0.4, metal: 0.6)
        for (a, b) in zip(centers, centers.dropFirst()) {
            let alongX = abs(a.y - b.y) < abs(a.x - b.x)
            lying(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), radius: u * 0.15,
                  length: alongX ? abs(b.x - a.x) : abs(b.y - a.y), base: 1 + u * 0.5,
                  alongX: alongX, material: pipe)
        }
    }

    /// Everything else: a suburb of small gabled houses and gardens. The
    /// startup garage is one house with a garage beside it.
    private mutating func housing() {
        let u = unit
        let houses = district == .startupGarage ? 2 : count(perUnits: 5, max: 40)
        for (index, cell) in grid(ground.insetBy(dx: u * 0.2, dy: u * 0.2), count: houses).enumerated() {
            if district != .startupGarage, rng.chance(0.18) {
                tree(CGPoint(x: cell.midX, y: cell.midY), size: Swift.min(cell.width, cell.height) * 0.35)
                continue
            }
            let house = CGRect(x: cell.minX + cell.width * rng.between(0.12, 0.22),
                               y: cell.minY + cell.height * rng.between(0.12, 0.22),
                               width: cell.width * rng.between(0.55, 0.7),
                               height: cell.height * rng.between(0.55, 0.7))
            guard house.width > 2, house.height > 2 else { continue }
            let height = Swift.min(Swift.min(house.width, house.height) * 0.6, u * 0.9) * CGFloat(district.heightScale) * 1.4
            let walls = materials.paint(rng.pick(Shade.render))
            box(house, height: height, top: walls, side: walls)
            if district == .startupGarage, index == 1 {
                // The garage: a flat roof and a big door.
                box(CGRect(x: house.minX, y: house.maxY - 0.3, width: house.width * 0.8, height: 0.4),
                    from: 1, height: height * 0.75, top: materials.paint(Shade.concrete),
                    side: materials.paint(Shade.concrete))
            } else {
                pyramid(house, from: 1 + height, height: height * 0.7, material: roof)
            }
        }
    }

    /// Cloud sync: a runway with markings, a terminal, a control tower, a plane.
    private mutating func airport() {
        let u = unit
        let wide = ground.width >= ground.height
        let strip = wide
            ? CGRect(x: ground.minX + u * 0.4, y: ground.midY - u, width: ground.width - u * 0.8, height: u * 2)
            : CGRect(x: ground.midX - u, y: ground.minY + u * 0.4, width: u * 2, height: ground.height - u * 0.8)
        slab(strip, from: 1, height: 0.15, material: materials.paint(Shade.runway))
        let dash = materials.paint(Shade.chalk)
        var along: CGFloat = u
        let length = wide ? strip.width : strip.height
        while along < length - u {
            let mark = wide ? CGRect(x: strip.minX + along, y: strip.midY - 0.3, width: u * 0.8, height: 0.6)
                            : CGRect(x: strip.midX - 0.3, y: strip.minY + along, width: 0.6, height: u * 0.8)
            slab(mark, from: 1.15, height: 0.05, material: dash)
            along += u * 1.6
        }

        let terminal = wide
            ? CGRect(x: ground.minX + u, y: ground.minY + u * 0.4, width: ground.width * 0.5,
                     height: Swift.max(0, strip.minY - ground.minY - u))
            : CGRect(x: ground.minX + u * 0.4, y: ground.minY + u, width: Swift.max(0, strip.minX - ground.minX - u),
                     height: ground.height * 0.5)
        if terminal.width > 3, terminal.height > 3 {
            box(terminal, height: u * 1.1, top: roof, side: materials.paint(Shade.cyan, rough: 0.2, metal: 0.4, windows: true))
        }
        let towerAt = CGPoint(x: ground.maxX - u * 1.5, y: ground.minY + u * 1.5)
        cylinder(towerAt, radius: u * 0.35, height: u * 4, material: materials.paint(Shade.concrete))
        cylinder(towerAt, radius: u * 0.7, from: 1 + u * 4, height: u * 0.8,
                 material: materials.paint(Shade.cyan, rough: 0.1, metal: 0.3, glow: 0.4))

        // A plane taxiing.
        let at = spot(in: strip.insetBy(dx: u * 2, dy: 0))
        let white = materials.paint(Shade.chalk, rough: 0.3)
        lying(at, radius: u * 0.3, length: u * 3, base: 1.2, alongX: wide, material: white)
        let wings = wide ? CGRect(x: at.x - u * 0.4, y: at.y - u * 1.4, width: u * 0.8, height: u * 2.8)
                         : CGRect(x: at.x - u * 1.4, y: at.y - u * 0.4, width: u * 2.8, height: u * 0.8)
        box(wings, from: 1.2 + u * 0.25, height: 0.3, top: white, side: white)
    }

    // MARK: - Garbage

    /// Landfill: heaps of rubbish with debris strewn over them and a bulldozer.
    /// The demolition site is the same in broken concrete.
    private mutating func mounds() {
        let u = unit
        let concrete = district == .rubble
        let layers = concrete ? Shade.rubble : Shade.heaps
        for _ in 0 ..< count(perUnits: 25, max: 6) {
            let center = spot(in: ground, margin: u)
            var radius = Swift.min(ground.width, ground.height) * rng.between(0.18, 0.32)
            var lift: CGFloat = 1
            for layer in layers {
                sphere(center, radius: radius, y: lift, material: materials.paint(layer, rough: 1),
                       squash: 0.45, stretch: CGPoint(x: rng.between(0.9, 1.4), y: 1))
                lift += radius * 0.12
                radius *= 0.72
            }
        }
        let bits = concrete ? Shade.rubble : Shade.debris
        for _ in 0 ..< Swift.max(10, Swift.min(70, Int(area / (u * u * 1.5)))) {
            let at = spot(in: ground)
            let size = u * rng.between(0.2, concrete ? 0.9 : 0.5)
            let colour = materials.paint(rng.pick(bits))
            box(CGRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size * rng.between(0.6, 1.4)),
                from: 1 + rng.between(0, u * 0.8), height: size * rng.between(0.4, 1), top: colour, side: colour,
                yaw: rng.between(0, .pi))
        }
        if ground.width > u * 5, ground.height > u * 4 {
            let at = spot(in: ground, margin: u * 2)
            let yellow = materials.paint(Shade.caution, rough: 0.5)
            box(CGRect(x: at.x - u, y: at.y - u * 0.6, width: u * 2, height: u * 1.2), height: u * 0.8,
                top: yellow, side: yellow)
            box(CGRect(x: at.x - u * 0.2, y: at.y - u * 0.5, width: u * 0.9, height: u), from: 1 + u * 0.8,
                height: u * 0.7, top: yellow, side: materials.paint(Shade.cyan, rough: 0.1))
            box(CGRect(x: at.x - u * 1.5, y: at.y - u * 0.8, width: u * 0.3, height: u * 1.6), height: u * 0.6,
                top: materials.paint(Shade.concrete), side: materials.paint(Shade.concrete))
        }
    }

    /// Scrapyard, junkyard and recycling depot: piles of wrecks or neat bales,
    /// and a crane with a magnet over the heap.
    private mutating func scrap() {
        let u = unit
        if district == .recyclingDepot {
            let size = u * 0.9
            var y = ground.minY + u * 0.4
            while y + size < ground.maxY - u * 0.3 {
                var x = ground.minX + u * 0.4
                while x + size < ground.maxX - u * 0.3 {
                    let tiers = Int(rng.between(1, 3.9))
                    for tier in 0 ..< tiers {
                        let colour = materials.paint(rng.pick(Shade.bales))
                        box(CGRect(x: x, y: y, width: size, height: size), from: 1 + CGFloat(tier) * size,
                            height: size, top: colour, side: colour)
                    }
                    x += size * 1.25
                }
                y += size * 1.4
            }
        } else {
            let colours = district == .junkyard ? Shade.debris : Shade.rust
            for _ in 0 ..< Swift.max(10, Swift.min(80, Int(area / (u * u * 1.5)))) {
                let at = spot(in: ground)
                let w = u * rng.between(0.8, 2)
                let d = u * rng.between(0.5, 1)
                let colour = materials.paint(rng.pick(colours), rough: 0.7, metal: 0.3)
                box(CGRect(x: at.x - w / 2, y: at.y - d / 2, width: w, height: d), from: 1 + rng.between(0, u * 0.9),
                    height: u * rng.between(0.4, 0.8), top: colour, side: colour, yaw: rng.between(0, .pi))
            }
        }
        if ground.width > u * 6, ground.height > u * 5 {
            let crane = materials.paint(Shade.caution, rough: 0.5, metal: 0.4)
            let foot = CGPoint(x: ground.minX + u * 1.5, y: ground.maxY - u * 1.5)
            cylinder(foot, radius: u * 0.3, height: u * 5, material: crane)
            box(CGRect(x: foot.x, y: foot.y - u * 0.2, width: u * 4.5, height: u * 0.4), from: 1 + u * 5,
                height: u * 0.4, top: crane, side: crane)
            cylinder(CGPoint(x: foot.x + u * 4, y: foot.y), radius: u * 0.6, from: 1 + u * 3.6, height: u * 0.3,
                     material: materials.paint(Shade.rubberBlack))
        }
    }

    /// Shantytown and ghost town: crowded shacks with tin roofs pitched every
    /// which way. The ghost town is faded, roofs fallen in, trees dead.
    private mutating func shacks() {
        let u = unit
        let ghost = district == .ghostTown
        for cell in grid(ground, count: count(perUnits: 2.4, max: 80, min: 4)) {
            let w = cell.width * rng.between(0.65, 0.95)
            let d = cell.height * rng.between(0.65, 0.95)
            let shack = CGRect(x: cell.minX + rng.between(0, cell.width - w),
                               y: cell.minY + rng.between(0, cell.height - d), width: w, height: d)
            guard shack.width > 1.5, shack.height > 1.5 else { continue }
            var tin = rng.pick(Shade.tin)
            if ghost { tin = Shade.faded(tin) }
            let height = Swift.min(Swift.min(w, d) * 0.8, u * 0.8) * rng.between(0.7, 1.3) * CGFloat(district.heightScale)
            let walls = materials.paint(ghost ? Shade.faded(Shade.plank) : rng.pick(Shade.tin))
            box(shack, height: height, top: walls, side: walls, yaw: rng.between(-0.15, 0.15))
            if ghost, rng.chance(0.3) { continue }      // the roof has fallen in
            // A lean-to roof: a thin sheet tipped to one side.
            let roofNode = SCNNode(geometry: materials.unitBox(top: materials.paint(tin, rough: 0.5, metal: 0.5),
                                                               side: materials.paint(tin, rough: 0.5, metal: 0.5)))
            roofNode.position = CityBuilder.world(shack.midX, shack.midY, y: (1 + height + 0.4) * Kit.s)
            roofNode.scale = SCNVector3((w + 0.6) * Kit.s, 0.25 * Kit.s, (d + 0.6) * Kit.s)
            roofNode.eulerAngles = SCNVector3(rng.between(-0.25, 0.25), 0, rng.between(-0.25, 0.25))
            root.addChildNode(roofNode)
        }
        if ghost {
            for _ in 0 ..< count(perUnits: 30, max: 6) { tree(spot(in: ground, margin: u), size: u, dead: true) }
        }
    }

    /// Crash dumps: glowing pools of ooze and stacks of leaking drums.
    private mutating func toxic() {
        let u = unit
        let ooze = materials.paint(Shade.ooze, rough: 0.2, glow: 0.9)
        for _ in 0 ..< count(perUnits: 25, max: 5) {
            let at = spot(in: ground, margin: u * 1.5)
            let radius = u * rng.between(1, 2.4)
            cylinder(at, radius: radius, from: 1, height: 0.3, material: ooze, squash: rng.between(0.5, 1))
        }
        let drum = u * 0.35
        var y = ground.minY + u * 0.6
        while y < ground.maxY - u * 0.4 {
            var x = ground.minX + u * 0.6
            while x < ground.maxX - u * 0.4 {
                if rng.chance(0.5) {
                    let colour = materials.paint(rng.chance(0.2) ? roofColour : Shade.barrel, rough: 0.5, metal: 0.4)
                    let tiers = rng.chance(0.3) ? 2 : 1
                    for tier in 0 ..< tiers {
                        cylinder(CGPoint(x: x, y: y), radius: drum, from: 1 + CGFloat(tier) * drum * 2.6,
                                 height: drum * 2.5, material: colour)
                    }
                }
                x += drum * 3
            }
            y += drum * 3.2
        }
        let post = materials.paint(Shade.caution)
        for corner in [CGPoint(x: ground.minX, y: ground.minY), CGPoint(x: ground.maxX, y: ground.minY),
                       CGPoint(x: ground.minX, y: ground.maxY), CGPoint(x: ground.maxX, y: ground.maxY)] {
            cylinder(corner, radius: 0.35, height: u * 1.2, material: post)
        }
    }

    /// Logs: timber stacked in pyramids, cut ends out, and a sawmill.
    private mutating func logs() {
        let u = unit
        let (yard, mill) = split(ground, share: 0.72)
        let radius = u * 0.28
        let length = u * rng.between(2.5, 4)
        let wood = materials.paint(Shade.wood)
        var y = yard.minY + u * 0.5
        while y + radius * 8 < yard.maxY {
            var x = yard.minX + u * 0.4
            while x + length < yard.maxX {
                // Three rows narrowing to the top.
                for tier in 0 ..< 3 {
                    let across = 4 - tier
                    for index in 0 ..< across {
                        let z = y + radius * (CGFloat(tier) + CGFloat(index) * 2 + 1)
                        lying(CGPoint(x: x + length / 2, y: z), radius: radius, length: length,
                              base: 1 + CGFloat(tier) * radius * 1.7, alongX: true, material: wood)
                    }
                }
                x += length + u * 0.8
            }
            y += radius * 9 + u * 0.6
        }
        let shed = mill.insetBy(dx: u * 0.4, dy: u * 0.4)
        if shed.width > 3, shed.height > 3 {
            box(shed, height: u * 1.2, top: roof, side: wood)
            pyramid(shed, from: 1 + u * 1.2, height: u * 0.6, material: roof)
        }
    }
}

/// Colours for scenery that is not tied to a file family.
enum Shade {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func faded(_ colour: CGColor) -> CGColor {
        let parts = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                     options: nil)?.components ?? [0.5, 0.5, 0.5]
        let grey = (parts[0] + parts[1] + parts[2]) / 3
        return rgb(grey + (parts[0] - grey) * 0.25, grey + (parts[1] - grey) * 0.25, grey + (parts[2] - grey) * 0.25)
    }

    static let sidewalk = rgb(0.30, 0.31, 0.34)
    static let dirt = rgb(0.36, 0.29, 0.18)
    static let chalk = rgb(0.92, 0.92, 0.90)
    static let stone = rgb(0.78, 0.75, 0.68)
    static let concrete = rgb(0.48, 0.49, 0.52)
    static let brick = rgb(0.55, 0.28, 0.22)
    static let bark = rgb(0.32, 0.22, 0.14)
    static let turf = rgb(0.24, 0.52, 0.30)
    static let track = rgb(0.72, 0.35, 0.28)
    static let water = rgb(0.20, 0.42, 0.65)
    static let runway = rgb(0.12, 0.12, 0.14)
    static let gold = rgb(0.85, 0.70, 0.30)
    static let cyan = rgb(0.45, 0.85, 1.00)
    static let lamp = rgb(1.00, 0.96, 0.75)
    static let flag = rgb(0.90, 0.30, 0.28)
    static let smoke = rgb(0.80, 0.80, 0.82)
    static let caution = rgb(0.95, 0.74, 0.20)
    static let rubberBlack = rgb(0.08, 0.08, 0.09)
    static let ooze = rgb(0.55, 0.95, 0.25)
    static let barrel = rgb(0.85, 0.68, 0.15)
    static let wood = rgb(0.55, 0.38, 0.22)
    static let plank = rgb(0.45, 0.35, 0.25)
    static let foliage = [rgb(0.20, 0.42, 0.24), rgb(0.24, 0.50, 0.27), rgb(0.17, 0.36, 0.22)]
    static let flagColours = [rgb(0.85, 0.25, 0.25), rgb(0.25, 0.45, 0.85), rgb(0.95, 0.85, 0.30),
                              rgb(0.30, 0.65, 0.40)]
    static let render = [rgb(0.85, 0.82, 0.75), rgb(0.78, 0.72, 0.62), rgb(0.70, 0.74, 0.78),
                         rgb(0.82, 0.76, 0.70)]
    static let containers = [rgb(0.70, 0.25, 0.20), rgb(0.20, 0.40, 0.65), rgb(0.25, 0.55, 0.45),
                             rgb(0.85, 0.55, 0.20), rgb(0.55, 0.55, 0.58)]
    static let heaps = [rgb(0.36, 0.29, 0.18), rgb(0.43, 0.35, 0.21), rgb(0.50, 0.41, 0.25)]
    static let rubble = [rgb(0.36, 0.36, 0.37), rgb(0.46, 0.45, 0.44), rgb(0.56, 0.55, 0.52)]
    static let debris = [rgb(0.80, 0.32, 0.28), rgb(0.30, 0.52, 0.80), rgb(0.88, 0.80, 0.42),
                         rgb(0.70, 0.70, 0.72), rgb(0.34, 0.62, 0.40), rgb(0.92, 0.92, 0.90)]
    static let rust = [rgb(0.55, 0.30, 0.18), rgb(0.45, 0.26, 0.17), rgb(0.40, 0.40, 0.42),
                       rgb(0.62, 0.40, 0.22)]
    static let bales = [rgb(0.35, 0.62, 0.40), rgb(0.35, 0.50, 0.75), rgb(0.85, 0.85, 0.82),
                        rgb(0.75, 0.62, 0.40)]
    static let tin = [rgb(0.55, 0.56, 0.58), rgb(0.58, 0.36, 0.24), rgb(0.25, 0.42, 0.65),
                      rgb(0.70, 0.62, 0.45), rgb(0.45, 0.55, 0.42)]
}

extension MaterialCache {
    /// Unit primitives, one per material combination, scaled per instance.
    /// Sharing them keeps the geometry count down before flattening.
    func unitBox(top: SCNMaterial, side: SCNMaterial) -> SCNGeometry {
        geometry("box", top, side) {
            let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
            // front, right, back, left, top, bottom
            box.materials = [side, side, side, side, top, side]
            return box
        }
    }

    func unitCylinder(_ material: SCNMaterial) -> SCNGeometry {
        geometry("cylinder", material, material) {
            let cylinder = SCNCylinder(radius: 0.5, height: 1)
            cylinder.radialSegmentCount = 16
            cylinder.materials = [material]
            return cylinder
        }
    }

    func unitSphere(_ material: SCNMaterial) -> SCNGeometry {
        geometry("sphere", material, material) {
            let sphere = SCNSphere(radius: 0.5)
            sphere.segmentCount = 16
            sphere.materials = [material]
            return sphere
        }
    }

    func unitCone(_ material: SCNMaterial) -> SCNGeometry {
        geometry("cone", material, material) {
            let cone = SCNCone(topRadius: 0, bottomRadius: 0.5, height: 1)
            cone.radialSegmentCount = 12
            cone.materials = [material]
            return cone
        }
    }

    func unitPyramid(_ material: SCNMaterial) -> SCNGeometry {
        geometry("pyramid", material, material) {
            let pyramid = SCNPyramid(width: 1, height: 1, length: 1)
            pyramid.materials = [material]
            return pyramid
        }
    }

    func unitTorus(_ material: SCNMaterial) -> SCNGeometry {
        geometry("torus", material, material) {
            let torus = SCNTorus(ringRadius: 0.47, pipeRadius: 0.03)
            torus.materials = [material]
            return torus
        }
    }

    func unitTube(_ material: SCNMaterial, inner: CGFloat) -> SCNGeometry {
        geometry("tube\(Int(inner * 100))", material, material) {
            let tube = SCNTube(innerRadius: (inner * 100).rounded() / 100, outerRadius: 0.5, height: 1)
            tube.radialSegmentCount = 32
            tube.materials = [material]
            return tube
        }
    }
}
