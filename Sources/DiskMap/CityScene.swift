import AppKit
import ReclaimKit
import SceneKit

/// What the 3D city needs to know about one tile. Plain values, gathered on the
/// main thread, so the scene can be built off it without touching the tree.
struct CityLot {
    let index: Int
    /// In layout points; the layout is built in a fixed square, not the view.
    let rect: CGRect
    let district: District
    let family: FileFamily
    let seed: UInt64
    let name: String
    let detail: String
}

/// Where the camera can be put with one click.
enum CityViewpoint: Int, CaseIterable {
    case overhead, tilted, street

    var title: String {
        switch self {
        case .overhead: return "Top"
        case .tilted: return "Tilt"
        case .street: return "Street"
        }
    }
}

protocol CitySceneViewHost: AnyObject {
    func city(_ view: CitySceneView, didHover index: Int?)
    func city(_ view: CitySceneView, didClick index: Int?, clickCount: Int)
    func city(_ view: CitySceneView, menuFor index: Int) -> NSMenu?
}

/// The folder in view as a 3D town, built with SceneKit.
///
/// Each tile is a block of the same footprint as on the flat map, so area still
/// means bytes; what is built on it comes from its `District`. The camera
/// orbits with a drag, pans with a two-finger or right-drag, and zooms with a
/// scroll or pinch — SceneKit's own camera controller — and three viewpoints
/// are a click away. Selection, hover and the Trash marks are drawn as tinted
/// glass boxes around a block, so changing them never rebuilds the town.
final class CitySceneView: SCNView {
    weak var host: CitySceneViewHost?

    /// The city is built in a square this many layout points across.
    static let layoutSide: CGFloat = 1000
    /// World units per layout point: the town is ten units across.
    static let scale: CGFloat = 0.01

    private let cityScene = SCNScene()
    private let cameraNode = SCNNode()
    private var townNode = SCNNode()
    private var overlayNode = SCNNode()
    private var blockNodes: [Int: SCNNode] = [:]
    private var blockHeights: [Int: CGFloat] = [:]
    private var lots: [Int: CityLot] = [:]
    private var buildGeneration = 0
    private var trackingArea: NSTrackingArea?
    private var mouseDownAt: NSPoint?
    private var hoveredIndex: Int?

    /// Bit for the blocks, so hit-testing skips labels and overlays.
    private static let blockCategory = 1 << 1

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        scene = cityScene
        backgroundColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
        antialiasingMode = .multisampling4X
        rendersContinuously = false
        preferredFramesPerSecond = 60

        cityScene.background.contents = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
        cityScene.fogStartDistance = 18
        cityScene.fogEndDistance = 55
        cityScene.fogColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)

        // The ground under and around the town.
        let floor = SCNFloor()
        floor.reflectivity = 0.04
        let asphalt = SCNMaterial()
        asphalt.diffuse.contents = TreemapRenderer.asphalt
        asphalt.lightingModel = .lambert
        floor.materials = [asphalt]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.001, 0)
        cityScene.rootNode.addChildNode(floorNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 380
        ambient.light?.color = NSColor(srgbRed: 0.75, green: 0.80, blue: 1.0, alpha: 1)
        cityScene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1100
        sun.light?.color = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.86, alpha: 1)
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowSampleCount = 8
        sun.light?.shadowRadius = 2
        sun.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.light?.shadowColor = NSColor(white: 0, alpha: 0.55)
        sun.light?.automaticallyAdjustsShadowProjection = true
        sun.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 5, 0)
        cityScene.rootNode.addChildNode(sun)

        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.zNear = 0.05
        camera.zFar = 200
        camera.wantsHDR = false
        cameraNode.camera = camera
        cityScene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        place(camera: .tilted, animated: false)

        allowsCameraControl = true
        defaultCameraController.interactionMode = .orbitTurntable
        defaultCameraController.inertiaEnabled = true
        defaultCameraController.target = SCNVector3Zero
        // Never under the ground, never quite straight down (the turntable flips there).
        defaultCameraController.minimumVerticalAngle = 4
        defaultCameraController.maximumVerticalAngle = 89

        cityScene.rootNode.addChildNode(townNode)
        cityScene.rootNode.addChildNode(overlayNode)
    }

    // MARK: Camera

    func place(camera viewpoint: CityViewpoint, animated: Bool = true) {
        let position: SCNVector3
        switch viewpoint {
        case .overhead: position = SCNVector3(0, 15, 0.01)
        case .tilted: position = SCNVector3(0, 8.5, 10)
        case .street: position = SCNVector3(5.5, 1.1, 6.5)
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.6 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.position = position
        cameraNode.look(at: viewpoint == .street ? SCNVector3(0, 0.6, 0) : SCNVector3Zero,
                        up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        SCNTransaction.commit()
        defaultCameraController.target = viewpoint == .street ? SCNVector3(0, 0.6, 0) : SCNVector3Zero
    }

    // MARK: Building

    /// Replaces the town. The geometry is built on a background queue from
    /// plain values, then swapped in on the main thread.
    func show(lots newLots: [CityLot]) {
        buildGeneration += 1
        let generation = buildGeneration
        hoveredIndex = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built = CityBuilder.build(newLots)
            DispatchQueue.main.async {
                guard let self, self.buildGeneration == generation else { return }
                self.townNode.removeFromParentNode()
                self.townNode = built.town
                self.cityScene.rootNode.addChildNode(built.town)
                self.blockNodes = built.blocks
                self.blockHeights = built.heights
                self.lots = Dictionary(uniqueKeysWithValues: newLots.map { ($0.index, $0) })
                for node in built.blocks.values { node.categoryBitMask = CitySceneView.blockCategory }
                self.refreshOverlays()
            }
        }
    }

    func clear() {
        buildGeneration += 1
        townNode.removeFromParentNode()
        townNode = SCNNode()
        cityScene.rootNode.addChildNode(townNode)
        blockNodes = [:]
        blockHeights = [:]
        lots = [:]
        marks = Marks()
        refreshOverlays()
    }

    // MARK: Overlays

    struct Marks: Equatable {
        var hovered: Int?
        var selected: Int?
        var highlighted: Int?
        var staged: Set<Int> = []
    }

    var marks = Marks() {
        didSet { if marks != oldValue { refreshOverlays() } }
    }

    private func refreshOverlays() {
        overlayNode.childNodes.forEach { $0.removeFromParentNode() }
        for index in marks.staged {
            addOverlay(index, colour: Theme.accent, alpha: 0.35)
        }
        if let index = marks.selected { addOverlay(index, colour: .white, alpha: 0.22) }
        if let index = marks.hovered ?? marks.highlighted {
            addOverlay(index, colour: Theme.accent, alpha: 0.28)
        }
    }

    private func addOverlay(_ index: Int, colour: NSColor, alpha: CGFloat) {
        guard let lot = lots[index] else { return }
        let height = (blockHeights[index] ?? 0.1) + 0.04
        let s = CitySceneView.scale
        let box = SCNBox(width: lot.rect.width * s + 0.01, height: height,
                         length: lot.rect.height * s + 0.01, chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = colour.withAlphaComponent(alpha)
        material.emission.contents = colour.withAlphaComponent(alpha * 0.8)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.blendMode = .alpha
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.position = CityBuilder.world(lot.rect.midX, lot.rect.midY, y: height / 2)
        node.renderingOrder = 10
        node.castsShadow = false
        overlayNode.addChildNode(node)
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func blockIndex(at point: NSPoint) -> Int? {
        let hits = hitTest(point, options: [
            .categoryBitMask: CitySceneView.blockCategory,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
        ])
        var node = hits.first?.node
        while let current = node {
            if let name = current.name, name.hasPrefix("block:"), let index = Int(name.dropFirst(6)) {
                return index
            }
            node = current.parent
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let index = blockIndex(at: convert(event.locationInWindow, from: nil))
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        host?.city(self, didHover: index)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoveredIndex != nil else { return }
        hoveredIndex = nil
        host?.city(self, didHover: nil)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // A drag turns the camera; only a click without movement picks a block.
        guard let start = mouseDownAt else { return }
        mouseDownAt = nil
        let end = event.locationInWindow
        guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }
        let index = blockIndex(at: convert(end, from: nil))
        host?.city(self, didClick: index, clickCount: event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = blockIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return host?.city(self, menuFor: index)
    }
}

// MARK: - Building the town

/// Turns lots into SceneKit nodes. Every block is assembled from primitives and
/// then flattened into a single node, so the scene draws a few hundred meshes
/// rather than tens of thousands of boxes.
enum CityBuilder {
    struct Town {
        let town: SCNNode
        let blocks: [Int: SCNNode]
        let heights: [Int: CGFloat]
    }

    static func world(_ x: CGFloat, _ y: CGFloat, y height: CGFloat) -> SCNVector3 {
        let s = CitySceneView.scale
        let half = CitySceneView.layoutSide / 2
        return SCNVector3((x - half) * s, height, (y - half) * s)
    }

    /// Labels go on the biggest blocks only; a label per speck is noise.
    static let labelledBlocks = 24

    static func build(_ lots: [CityLot]) -> Town {
        let town = SCNNode()
        var blocks: [Int: SCNNode] = [:]
        var heights: [Int: CGFloat] = [:]
        let materials = MaterialCache()

        let labelled = Set(lots.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .prefix(labelledBlocks)
            .filter { $0.rect.width > 60 && $0.rect.height > 40 }
            .map(\.index))

        for lot in lots {
            var kit = Kit(lot: lot, materials: materials, rng: SplitMix64(seed: lot.seed))
            kit.build()
            let flat = kit.root.flattenedClone()
            flat.name = "block:\(lot.index)"
            flat.castsShadow = true
            town.addChildNode(flat)
            blocks[lot.index] = flat
            heights[lot.index] = kit.tallest

            if labelled.contains(lot.index) {
                let label = CityLabel.node(name: lot.name, detail: lot.detail, district: lot.district)
                label.position = world(lot.rect.midX, lot.rect.midY, y: kit.tallest + 0.35)
                town.addChildNode(label)
            }
        }
        return Town(town: town, blocks: blocks, heights: heights)
    }
}

/// Materials shared across the whole town, keyed by colour, so flattened
/// blocks still batch by material.
final class MaterialCache {
    private var cache: [String: SCNMaterial] = [:]
    private var geometries: [String: SCNGeometry] = [:]

    /// One shared geometry per primitive and material pair; instances are scaled.
    func geometry(_ kind: String, _ first: SCNMaterial, _ second: SCNMaterial,
                  make: () -> SCNGeometry) -> SCNGeometry {
        let key = "\(kind)|\(ObjectIdentifier(first).hashValue)|\(ObjectIdentifier(second).hashValue)"
        if let hit = geometries[key] { return hit }
        let made = make()
        geometries[key] = made
        return made
    }

    func paint(_ colour: CGColor, rough: CGFloat = 0.85, metal: CGFloat = 0,
               glow: CGFloat = 0, windows: Bool = false) -> SCNMaterial {
        let parts = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                     options: nil)?.components ?? [0.5, 0.5, 0.5, 1]
        let key = parts.map { String(format: "%.3f", $0) }.joined(separator: ",")
            + "|\(rough)|\(metal)|\(glow)|\(windows)"
        if let hit = cache[key] { return hit }
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = colour
        material.roughness.contents = rough
        material.metalness.contents = metal
        if glow > 0 {
            material.emission.contents = colour.copy(alpha: glow) ?? colour
        }
        if windows {
            material.emission.contents = MaterialCache.windowTexture
            material.emission.wrapS = .repeat
            material.emission.wrapT = .repeat
            material.emission.contentsTransform = SCNMatrix4MakeScale(3, 6, 1)
            material.emission.intensity = 0.9
        }
        cache[key] = material
        return material
    }

    /// Rows of lit and dark windows, tiled over tower walls as emission.
    static let windowTexture: NSImage = {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            var rng = SplitMix64(seed: 7)
            for row in 0 ..< 4 {
                for column in 0 ..< 4 {
                    let lit = rng.unit() < 0.6
                    (lit ? NSColor(srgbRed: 1, green: 0.88, blue: 0.6, alpha: 1)
                         : NSColor(white: 0.08, alpha: 1)).setFill()
                    NSRect(x: CGFloat(column) * 16 + 4, y: CGFloat(row) * 16 + 4, width: 8, height: 9).fill()
                }
            }
            return true
        }
    }()
}

/// A floating sign over a block: its name, its size, and what it is.
enum CityLabel {
    static func node(name: String, detail: String, district: District) -> SCNNode {
        let image = render(name: name, detail: "\(detail)  ·  \(district.label)")
        let height: CGFloat = 0.32
        let plane = SCNPlane(width: height * image.size.width / max(image.size.height, 1), height: height)
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 20
        node.castsShadow = false
        node.name = "label"
        return node
    }

    private static func render(name: String, detail: String) -> NSImage {
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]
        let title = String(name.prefix(40)) as NSString
        let line = detail as NSString
        let width = ceil(max(title.size(withAttributes: nameAttributes).width,
                             line.size(withAttributes: detailAttributes).width)) + 28
        let size = NSSize(width: width, height: 70)
        return NSImage(size: size, flipped: true) { rect in
            NSColor.black.withAlphaComponent(0.66).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            title.draw(at: NSPoint(x: 14, y: 6), withAttributes: nameAttributes)
            line.draw(at: NSPoint(x: 14, y: 40), withAttributes: detailAttributes)
            return true
        }
    }
}
