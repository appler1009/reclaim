import AppKit
import ReclaimKit

protocol TreemapViewDelegate: AnyObject {
    func treemap(_ view: TreemapView, didHover cell: TreemapCell?)
    func treemap(_ view: TreemapView, didSelect cell: TreemapCell?)
    func treemap(_ view: TreemapView, didActivate item: FileItem)
    func treemapDidRequestUp(_ view: TreemapView)
    func treemap(_ view: TreemapView, didRequestTrash item: FileItem)
    func treemap(_ view: TreemapView, didRequestReveal item: FileItem)
    func treemap(_ view: TreemapView, didToggleSelection item: FileItem)
    /// Whether the item is currently ticked for removal, for the menu's title.
    func treemap(_ view: TreemapView, isStaged item: FileItem) -> Bool
}

/// Renders a squarified treemap of the folder currently in view.
///
/// Only one level is drawn: every immediate child is a single tile, whatever is
/// inside it. Drilling into a folder re-lays the map for that folder. That keeps
/// the picture readable (dozens of tiles, all labelled) instead of a mosaic of
/// sub-pixel specks, and makes a full relayout essentially free.
///
/// The map is drawn live from the layout on every pass — never blitted from a
/// cached bitmap — so it is always sharp and always laid out for the size it is
/// actually being displayed at, including mid-resize. Hover and selection only
/// invalidate the rectangles that changed, so pointer movement stays cheap.
final class TreemapView: NSView {
    weak var delegate: TreemapViewDelegate?

    private(set) var root: FileItem?
    private var layout = TreemapLayout() {
        didSet { layoutDidChange() }
    }
    /// The district of every cell in `layout`, in order, worked out once per layout.
    private var districts: [District] = []
    /// The 3D town, while the map is shown as one.
    private var city: CitySceneView?
    private let styleControl = NSSegmentedControl(labels: ["Flat", "3D"], trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let viewpointControl = NSSegmentedControl(labels: CityViewpoint.allCases.map(\.title),
                                                      trackingMode: .momentary, target: nil, action: nil)
    /// Where the map style is remembered between launches.
    static let cityDefaultsKey = "MapIsCity"

    /// Whether the map is drawn as a 3D town (true) or the flat city map.
    /// The town is laid out in a fixed square, so resizing never rebuilds it.
    var isCity = false {
        didSet {
            guard isCity != oldValue else { return }
            applyStyle()
        }
    }
    private var generation = 0
    /// How long the last layout took, used to decide whether it can be done inline.
    private var lastLayoutDuration: TimeInterval = 0
    private var hovered: TreemapCell?
    /// A tile highlighted from outside the map, because the pointer is over the
    /// matching row in the contents list rather than over the map itself.
    private(set) var highlighted: FileItem?
    private var selected: FileItem?
    private var trackingArea: NSTrackingArea?
    private var transition: TreemapTransition?
    private var transitionTimer: Timer?
    private var scrollNavigator = ScrollNavigator()

    var measure: SizeMeasure = .physical { didSet { rebuild() } }

    /// Set while the sidebar divider is being dragged.
    ///
    /// A divider drag resizes this view continuously exactly like a window
    /// resize, but AppKit's `inLiveResize` only covers the window, so the map
    /// had no idea it was happening: it kept drawing labels and a hover
    /// highlight belonging to a layout that no longer existed.
    var isResizing = false {
        didSet {
            guard isResizing != oldValue else { return }
            if isResizing, hovered != nil {
                hovered = nil
                delegate?.treemap(self, didHover: nil)
            }
            needsDisplay = true
        }
    }

    /// True whenever the view is being resized, by the window or the divider.
    private var isLiveResizing: Bool { inLiveResize || isResizing }
    /// Nodes the user has picked for the Trash.
    var stagedMarks: Set<ObjectIdentifier> = [] {
        didSet { expandedStaged = nil; needsDisplay = true; syncCityMarks() }
    }
    /// Cache of `stagedMarks` expanded over the current layout's cells.
    private var expandedStaged: Set<ObjectIdentifier>?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The map paints every pixel it owns, so AppKit need not clear behind it.
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
        installControls()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
        installControls()
    }

    /// Redraw while the view is being resized rather than letting AppKit stretch
    /// or clear the old contents — dragging the sidebar divider resizes this view
    /// continuously, and the default policy showed as a flash on every frame.
    private func configureLayer() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = TreemapRenderer.asphalt
        layer?.isOpaque = true
    }

    func show(root: FileItem?) {
        let previousLayout = layout
        let previousRoot = self.root
        // The town rebuilds rather than zooming; the flat map zooms.
        let zooming = !isCity && root != nil && previousRoot != nil
            && (root?.parent === previousRoot || previousRoot?.parent === root)
        if !zooming {
            endTransition()
        }
        self.root = root
        selected = nil
        hovered = nil
        highlighted = nil
        if !zooming {
            var dropped = previousLayout
            dropped.detach()
            if previousRoot !== root {
                TreeRelease.later(previousRoot)
            }
        }
        rebuild()

        // Anchor the zoom on the tile the move pivots around: the folder being
        // entered (found in the old map) or the one being left (found in the new).
        guard zooming, let root, let previousRoot, root !== previousRoot else { return }
        if let entered = previousLayout.cells.first(where: { $0.item === root }) {
            start(TreemapTransition(previous: previousLayout, focus: entered.rect, goingIn: true))
        } else if let left = layout.cells.first(where: { $0.item === previousRoot }) {
            start(TreemapTransition(previous: previousLayout, focus: left.rect, goingIn: false))
        }
    }

    // MARK: - Transition

    private func start(_ transition: TreemapTransition) {
        self.transition = transition
        transitionTimer?.invalidate()
        // Driven off the display so the zoom lands on frame boundaries.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.transition?.isFinished ?? true {
                timer.invalidate()
                self.transition = nil
                self.transitionTimer = nil
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps running during scrolling
        transitionTimer = timer
        needsDisplay = true
    }

    private func endTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transition = nil
    }

    /// Drops the cells before their items are replaced. Cells hold items
    /// `unowned`, so freeing children first would leave the map pointing at
    /// released nodes until the next layout.
    func dropCells() {
        endTransition()
        layout.cells.removeAll()
        hovered = nil
        selected = nil
        highlighted = nil
        needsDisplay = true
    }

    /// Re-lays out the folder in view without treating it as navigation, for
    /// when its contents changed underneath us.
    func reload() {
        hovered = nil
        rebuild()
    }

    /// Currently selected node, so SwiftUI can avoid redundant updates.
    var selectedItemIdentity: FileItem? { selected }

    /// The tiles currently laid out, for tests.
    var laidOutItemsForTesting: [FileItem] { layout.cells.map(\.item) }

    func select(_ item: FileItem?) {
        selected = item
        needsDisplay = true
        syncCityMarks()
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The town has its own fixed layout; the scene view just resizes.
        if isCity, !layout.cells.isEmpty { return }
        if ProcessInfo.processInfo.environment["RECLAIM_TRACE_MAP"] != nil, let window {
            let inWindow = convert(bounds, to: nil)
            Log.debug("map geometry", [
                "frame": "\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))",
                "inWindow": "\(Int(inWindow.minY))..\(Int(inWindow.maxY))",
                "windowHeight": "\(Int(window.frame.height))",
                "visibleRect": "\(Int(visibleRect.minY))..\(Int(visibleRect.maxY))",
            ])
        }
        rebuild()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        rebuild()   // back to full detail
    }

    private func rebuild() {
        let side = CitySceneView.layoutSide
        let box = isCity ? CGRect(x: 0, y: 0, width: side, height: side) : bounds
        guard let root, box.width > 4, box.height > 4 else {
            layout = TreemapLayout()
            needsDisplay = true
            return
        }
        generation += 1
        let token = generation
        let measure = self.measure
        let minimumArea: CGFloat = 16

        // Lay out inline when that is fast enough, so the map on screen always
        // matches the current size instead of lagging a frame behind.
        if isLiveResizing || lastLayoutDuration < 0.020 {
            let started = DispatchTime.now().uptimeNanoseconds
            layout = TreemapLayout.build(root: root, in: box, measure: measure,
                                         minimumArea: minimumArea, maximumDepth: 1)
            expandedStaged = nil
            scrollNavigator.reset()
            lastLayoutDuration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            refreshHoverForNewLayout()
            needsDisplay = true
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let computed = TreemapLayout.build(root: root, in: box, measure: measure,
                                               minimumArea: minimumArea, maximumDepth: 1)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            DispatchQueue.main.async {
                guard let self, self.generation == token else {
                    var discarded = computed
                    discarded.detach()
                    return
                }
                self.layout = computed
                self.expandedStaged = nil
                self.lastLayoutDuration = elapsed
                self.refreshHoverForNewLayout()
                self.needsDisplay = true
            }
        }
    }

    /// The cell under the pointer is remembered by value, so after a relayout —
    /// resizing the sidebar, for one — the highlight would be drawn at the tile's
    /// old rectangle. Re-resolve it against the cells that now exist.
    private func refreshHoverForNewLayout() {
        guard !isCity else { return }   // the town tracks its own pointer
        guard !isResizing else { hovered = nil; return }
        guard hovered != nil || transition != nil else { return }
        guard let window, window.isKeyWindow else { hovered = nil; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { hovered = nil; return }
        let cell = layout.item(at: point)
        if cell?.item !== hovered?.item {
            delegate?.treemap(self, didHover: cell)
        }
        hovered = cell
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if isCity {
            // The scene view covers everything; this is only seen while it loads.
            context.setFillColor(TreemapRenderer.asphalt)
            context.fill(dirtyRect)
            return
        }

        if let transition, !transition.isFinished {
            context.setFillColor(TreemapRenderer.asphalt)
            context.fill(bounds)

            let outgoing = transition.outgoing(in: bounds)
            context.saveGState()
            context.setAlpha(outgoing.alpha)
            context.concatenate(outgoing.transform)
            TreemapRenderer.draw(layout: transition.previous, in: context, dirty: .infinite,
                                 measure: measure, staged: stagedNodes, fillBackground: false)
            context.restoreGState()

            let incoming = transition.incoming(in: bounds)
            context.saveGState()
            context.setAlpha(incoming.alpha)
            context.concatenate(incoming.transform)
            TreemapRenderer.draw(layout: layout, in: context, dirty: .infinite,
                                 measure: measure, staged: stagedNodes, districts: districts,
                                 fillBackground: false)
            context.restoreGState()
            return      // labels and chrome land when the movement settles
        }

        TreemapRenderer.draw(layout: layout, in: context, dirty: dirtyRect,
                             measure: measure, staged: stagedNodes, districts: districts)
        // Labels are the expensive part of a redraw and unreadable mid-drag.
        if !isLiveResizing { drawLabels(in: dirtyRect) }
        if !isResizing { drawChrome() }
    }

    /// Staged nodes expanded to include everything inside them, so a selected
    /// folder highlights its whole subtree without a per-cell parent walk.
    private var stagedNodes: Set<ObjectIdentifier> {
        guard !stagedMarks.isEmpty else { return [] }
        if let cached = expandedStaged { return cached }
        var expanded = Set<ObjectIdentifier>()
        for cell in layout.cells where isStaged(cell.item) {
            expanded.insert(ObjectIdentifier(cell.item))
        }
        expandedStaged = expanded
        return expanded
    }

    /// Labels sit on a dark sign in the block's corner, so they read the same
    /// over a glass tower, a football pitch or a rubbish heap.
    private func drawLabels(in dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: paragraph,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            .paragraphStyle: paragraph,
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            .paragraphStyle: paragraph,
        ]

        for (index, cell) in layout.cells.enumerated()
        where cell.rect.width > 52 && cell.rect.height > 18 && cell.rect.intersects(dirtyRect) {
            // Clip to the tile: a label must never bleed over its own border,
            // and the text box below is allowed to be taller than what is left.
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: cell.rect)

            var lines: [(text: String, attributes: [NSAttributedString.Key: Any], height: CGFloat)] = [
                (cell.item.name, nameAttributes, 14),
            ]
            if cell.rect.height > 34 && cell.rect.width > 84 {
                var detail = ByteFormat.string(cell.item.size(measure))
                if let total = root?.size(measure), total > 0 {
                    let share = Double(cell.item.size(measure)) / Double(total) * 100
                    detail += String(format: "  ·  %.0f%%", share)
                }
                lines.append((detail, detailAttributes, 13))

                // What the block is, and for a folder how much it stands for.
                if cell.rect.height > 52, cell.rect.width > 110 {
                    var note = index < districts.count ? districts[index].label : ""
                    if cell.item.isDirectory {
                        let files = cell.item.fileCount
                        note = "\(files.formatted()) file\(files == 1 ? "" : "s")  ·  " + note
                    }
                    lines.append((note, noteAttributes, 12))
                }
            }

            let inset = cell.rect.insetBy(dx: 8, dy: 7)
            let widest = lines.map { ($0.text as NSString).size(withAttributes: $0.attributes).width }
                .max() ?? 0
            let sign = CGRect(x: inset.minX - 4, y: inset.minY - 3,
                              width: min(inset.width, ceil(widest)) + 8,
                              height: lines.reduce(0) { $0 + $1.height + 1 } + 4)
            context.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            context.addPath(CGPath(roundedRect: sign, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()

            var y = inset.minY
            for line in lines {
                (line.text as NSString).draw(
                    with: CGRect(x: inset.minX, y: y, width: inset.width, height: line.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: line.attributes)
                y += line.height + 1
            }
        }
    }

    private func drawChrome() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let selected, let rect = frame(of: selected) {
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.stroke(rect.insetBy(dx: 1, dy: 1))
        }
        if let hovered {
            context.setStrokeColor(Theme.accent.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.5)
            context.stroke(hovered.rect.insetBy(dx: 0.75, dy: 0.75))
        }
        if let highlighted, let rect = frame(of: highlighted) {
            context.setStrokeColor(Theme.accent.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        }
    }

    /// Outlines the tile for `item` as though the pointer were on it.
    ///
    /// Drives the map from the contents list: hovering a row lights its tile.
    /// The pointer's own hover already draws itself, so an item the map is
    /// hovering is left alone rather than outlined twice.
    func highlight(_ item: FileItem?) {
        let wanted = item === hovered?.item ? nil : item
        guard wanted !== highlighted else { return }
        let previous = highlighted.flatMap(frame(of:))
        highlighted = wanted
        syncCityMarks()
        if let previous { setNeedsDisplay(previous.insetBy(dx: -2, dy: -2)) }
        if let rect = wanted.flatMap(frame(of:)) { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
    }

    private func frame(of item: FileItem) -> CGRect? {
        var union: CGRect?
        for cell in layout.cells where cell.item === item || cell.item.isDescendant(of: item) {
            union = union.map { $0.union(cell.rect) } ?? cell.rect
        }
        return union
    }

    // MARK: - Selection lookup

    private func isStaged(_ item: FileItem) -> Bool {
        guard !stagedMarks.isEmpty else { return false }
        var node: FileItem? = item
        while let current = node {
            if stagedMarks.contains(ObjectIdentifier(current)) { return true }
            node = current.parent
        }
        return false
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isResizing, !isCity else { return }
        let point = convert(event.locationInWindow, from: nil)
        let cell = layout.item(at: point)
        guard cell?.item !== hovered?.item else { return }
        let previous = hovered?.rect
        hovered = cell
        // The pointer owns the outline now; drop any list-driven one on the
        // same tile so it is not stroked twice.
        if highlighted === cell?.item { highlighted = nil }
        delegate?.treemap(self, didHover: cell)
        // Only the outgoing and incoming outlines changed.
        if let previous { setNeedsDisplay(previous.insetBy(dx: -2, dy: -2)) }
        if let rect = cell?.rect { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
    }

    override func mouseExited(with event: NSEvent) {
        guard !isCity else { return }
        let previous = hovered?.rect
        hovered = nil
        delegate?.treemap(self, didHover: nil)
        if let previous { setNeedsDisplay(previous.insetBy(dx: -2, dy: -2)) }
    }

    /// Scrolling navigates the hierarchy: scrolling down goes *into* the folder
    /// under the pointer, scrolling up comes back out — the content moves the way
    /// the fingers do, as when scrolling down a page to go deeper into it.
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.deltaY
        guard let step = scrollNavigator.accept(delta: delta,
                                                isMomentum: event.momentumPhase != [],
                                                isGestureStart: event.phase == .began) else {
            return
        }
        switch step {
        case .deeper:
            let point = convert(event.locationInWindow, from: nil)
            guard let cell = layout.item(at: point), cell.item.isDirectory,
                  !cell.item.children.isEmpty else { return }
            hovered = nil
            delegate?.treemap(self, didActivate: cell.item)
        case .out:
            hovered = nil
            delegate?.treemapDidRequestUp(self)
        }
    }

    // MARK: - Context menu

    /// The tile the open context menu applies to.
    private var contextItem: FileItem?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = layout.item(at: point) else { return nil }
        return menu(for: cell)
    }

    fileprivate func menu(for cell: TreemapCell) -> NSMenu {
        let item = cell.item
        contextItem = item

        // Right-clicking also selects, so it is obvious what the menu acts on.
        selected = item
        delegate?.treemap(self, didSelect: cell)
        needsDisplay = true
        syncCityMarks()

        let menu = NSMenu()
        menu.autoenablesItems = false

        let heading = NSMenuItem(title: "\(item.name) — \(ByteFormat.string(item.size(measure)))",
                                 action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        // Say what the block is. For the garbage districts this is the map's
        // hint that it can go; removing it is still the user's decision.
        if let index = layout.cells.firstIndex(where: { $0.item === item }), index < districts.count {
            let district = districts[index]
            let note = NSMenuItem(title: "\(district.label): \(district.hint)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            if district.isGarbage {
                note.attributedTitle = NSAttributedString(
                    string: note.title + " — usually safe to remove",
                    attributes: [.foregroundColor: Theme.accent])
            }
            menu.addItem(note)
        }
        menu.addItem(.separator())

        if item.isDirectory, !item.children.isEmpty {
            menu.addItem(entry("Open in Map", #selector(openInMap)))
        }
        menu.addItem(entry("Reveal in Finder", #selector(revealInFinder)))
        menu.addItem(entry("Copy Path", #selector(copyPath)))
        menu.addItem(.separator())

        let isStaged = delegate?.treemap(self, isStaged: item) ?? false
        menu.addItem(entry(isStaged ? "Remove from Selection" : "Select for Trash",
                           #selector(toggleSelection)))

        let trash = entry("Move “\(item.name)” to Trash", #selector(moveToTrash))
        trash.attributedTitle = NSAttributedString(
            string: trash.title,
            attributes: [.foregroundColor: Theme.accent])
        menu.addItem(trash)
        return menu
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openInMap() {
        guard let contextItem else { return }
        delegate?.treemap(self, didActivate: contextItem)
    }

    @objc private func revealInFinder() {
        guard let contextItem else { return }
        delegate?.treemap(self, didRequestReveal: contextItem)
    }

    @objc private func copyPath() {
        guard let contextItem else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contextItem.path, forType: .string)
    }

    @objc private func toggleSelection() {
        guard let contextItem else { return }
        delegate?.treemap(self, didToggleSelection: contextItem)
    }

    @objc private func moveToTrash() {
        guard let contextItem else { return }
        delegate?.treemap(self, didRequestTrash: contextItem)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cell = layout.item(at: point)
        selected = cell?.item
        delegate?.treemap(self, didSelect: cell)
        needsDisplay = true
        if event.clickCount == 2, let item = cell?.item {
            delegate?.treemap(self, didActivate: item)
        }
    }
}

// MARK: - City

extension TreemapView: CitySceneViewHost {
    private func installControls() {
        styleControl.target = self
        styleControl.action = #selector(styleChanged)
        styleControl.controlSize = .small
        styleControl.segmentStyle = .rounded
        styleControl.toolTip = "Show the folder as a flat map or a 3D town"
        viewpointControl.target = self
        viewpointControl.action = #selector(viewpointChosen)
        viewpointControl.controlSize = .small
        viewpointControl.segmentStyle = .rounded
        viewpointControl.toolTip = "Move the camera. Drag to orbit, scroll or pinch to zoom."
        for control in [styleControl, viewpointControl] {
            control.sizeToFit()
            control.autoresizingMask = [.minXMargin, .maxYMargin]
            addSubview(control)
        }
        layoutControls()
        applyStyle()
    }

    private func layoutControls() {
        let margin: CGFloat = 10
        styleControl.setFrameOrigin(NSPoint(x: bounds.maxX - styleControl.frame.width - margin, y: margin))
        viewpointControl.setFrameOrigin(NSPoint(x: styleControl.frame.minX - viewpointControl.frame.width - 8,
                                                y: margin))
    }

    @objc private func styleChanged() {
        isCity = styleControl.selectedSegment == 1
        UserDefaults.standard.set(isCity, forKey: TreemapView.cityDefaultsKey)
    }

    @objc private func viewpointChosen() {
        guard let viewpoint = CityViewpoint(rawValue: viewpointControl.selectedSegment) else { return }
        city?.place(camera: viewpoint)
    }

    private func applyStyle() {
        styleControl.selectedSegment = isCity ? 1 : 0
        viewpointControl.isHidden = !isCity
        endTransition()
        if hovered != nil {
            hovered = nil
            delegate?.treemap(self, didHover: nil)
        }
        if isCity {
            if city == nil {
                let scene = CitySceneView(frame: bounds, options: nil)
                scene.autoresizingMask = [.width, .height]
                scene.host = self
                addSubview(scene, positioned: .below, relativeTo: viewpointControl)
                city = scene
            }
        } else {
            city?.removeFromSuperview()
            city = nil
        }
        layoutControls()
        rebuild()
        needsDisplay = true
    }

    /// Zones the new layout and hands it to the town.
    private func layoutDidChange() {
        districts = layout.zoned(measure)
        guard let city else { return }
        guard !layout.cells.isEmpty else { city.clear(); return }
        let total = root?.size(measure) ?? 0
        let lots = layout.cells.enumerated().map { index, cell -> CityLot in
            let bytes = cell.item.size(measure)
            var detail = ByteFormat.string(bytes)
            if total > 0 { detail += String(format: "  ·  %.0f%%", Double(bytes) / Double(total) * 100) }
            return CityLot(index: index, rect: cell.rect, district: districts[index],
                           family: cell.item.dominantFamily(measure),
                           seed: CityBlock.seed(cell.item.name), name: cell.item.name, detail: detail)
        }
        city.show(lots: lots)
        syncCityMarks()
    }

    private func cellIndex(of item: FileItem?) -> Int? {
        guard let item else { return nil }
        return layout.cells.firstIndex { $0.item === item }
    }

    private func syncCityMarks() {
        guard let city else { return }
        var marks = CitySceneView.Marks()
        marks.hovered = cellIndex(of: hovered?.item)
        marks.selected = cellIndex(of: selected)
        marks.highlighted = cellIndex(of: highlighted)
        let staged = stagedNodes
        if !staged.isEmpty {
            marks.staged = Set(layout.cells.indices.filter { staged.contains(ObjectIdentifier(layout.cells[$0].item)) })
        }
        city.marks = marks
    }

    func city(_ view: CitySceneView, didHover index: Int?) {
        let cell = index.flatMap { $0 < layout.cells.count ? layout.cells[$0] : nil }
        hovered = cell
        if highlighted === cell?.item { highlighted = nil }
        delegate?.treemap(self, didHover: cell)
        syncCityMarks()
    }

    func city(_ view: CitySceneView, didClick index: Int?, clickCount: Int) {
        let cell = index.flatMap { $0 < layout.cells.count ? layout.cells[$0] : nil }
        selected = cell?.item
        delegate?.treemap(self, didSelect: cell)
        syncCityMarks()
        if clickCount == 2, let item = cell?.item, item.isDirectory, !item.children.isEmpty {
            delegate?.treemap(self, didActivate: item)
        }
    }

    func city(_ view: CitySceneView, menuFor index: Int) -> NSMenu? {
        guard index < layout.cells.count else { return nil }
        return menu(for: layout.cells[index])
    }
}
