import AppKit

protocol TreemapViewDelegate: AnyObject {
    func treemap(_ view: TreemapView, didHover cell: TreemapCell?)
    func treemap(_ view: TreemapView, didSelect cell: TreemapCell?)
    func treemap(_ view: TreemapView, didActivate item: FileItem)
    func treemapDidRequestUp(_ view: TreemapView)
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
    private var layout = TreemapLayout()
    private var generation = 0
    /// How long the last layout took, used to decide whether it can be done inline.
    private var lastLayoutDuration: TimeInterval = 0
    private var hovered: TreemapCell?
    private var selected: FileItem?
    private var trackingArea: NSTrackingArea?
    private var transition: TreemapTransition?
    private var transitionTimer: Timer?
    private var scrollAccumulator: CGFloat = 0
    private var scrollCooldownEnds = Date.distantPast

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
        didSet { expandedStaged = nil; needsDisplay = true }
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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    /// Redraw while the view is being resized rather than letting AppKit stretch
    /// or clear the old contents — dragging the sidebar divider resizes this view
    /// continuously, and the default policy showed as a flash on every frame.
    private func configureLayer() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = Theme.background.cgColor
        layer?.isOpaque = true
    }

    func show(root: FileItem?) {
        let previousLayout = layout
        let previousRoot = self.root
        self.root = root
        selected = nil
        hovered = nil
        rebuild()

        // Anchor the zoom on the tile the move pivots around: the folder being
        // entered (found in the old map) or the one being left (found in the new).
        guard let root, let previousRoot, root !== previousRoot else { return }
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
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
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
        guard let root, bounds.width > 4, bounds.height > 4 else {
            layout = TreemapLayout()
            needsDisplay = true
            return
        }
        generation += 1
        let token = generation
        let box = bounds
        let measure = self.measure
        let minimumArea: CGFloat = 16

        // Lay out inline when that is fast enough, so the map on screen always
        // matches the current size instead of lagging a frame behind.
        if isLiveResizing || lastLayoutDuration < 0.020 {
            let started = DispatchTime.now().uptimeNanoseconds
            layout = TreemapLayout.build(root: root, in: box, measure: measure,
                                         minimumArea: minimumArea, maximumDepth: 1)
            expandedStaged = nil
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
                guard let self, self.generation == token else { return }
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

        if let transition, !transition.isFinished {
            context.setFillColor(Theme.background.cgColor)
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
                                 measure: measure, staged: stagedNodes, fillBackground: false)
            context.restoreGState()
            return      // labels and chrome land when the movement settles
        }

        TreemapRenderer.draw(layout: layout, in: context, dirty: dirtyRect,
                             measure: measure, staged: stagedNodes)
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

    private func drawLabels(in dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for cell in layout.cells
        where cell.rect.width > 52 && cell.rect.height > 18 && cell.rect.intersects(dirtyRect) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            // Bright tiles get dark text, so a label never washes out.
            let tint = TreemapRenderer.tileColor(family: cell.item.dominantFamily(measure),
                                                 depth: cell.depth,
                                                 staged: stagedNodes.contains(ObjectIdentifier(cell.item)))
            let light = TreemapRenderer.isLight(tint)
            let ink: NSColor = light ? .black : .white
            // A nil value must be left out of the attributes entirely: passing
            // `Optional.none as Any` for .shadow makes AppKit throw mid-draw.
            let shadow: [NSAttributedString.Key: Any] = light ? [:] : [.shadow: labelShadow]
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(light ? 0.82 : 0.95),
                .paragraphStyle: paragraph,
            ].merging(shadow) { current, _ in current }
            // Clip to the tile: a label must never bleed over its own border,
            // and the text box below is allowed to be taller than what is left.
            context.saveGState()
            context.clip(to: cell.rect)
            defer { context.restoreGState() }

            let inset = cell.rect.insetBy(dx: 6, dy: 5)
            (cell.item.name as NSString).draw(
                with: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: nameAttributes)

            if cell.rect.height > 34 && cell.rect.width > 84 {
                let detailAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: ink.withAlphaComponent(light ? 0.66 : 0.72),
                    .paragraphStyle: paragraph,
                ].merging(shadow) { current, _ in current }
                var detail = ByteFormat.string(cell.item.size(measure))
                if let total = root?.size(measure), total > 0 {
                    let share = Double(cell.item.size(measure)) / Double(total) * 100
                    detail += String(format: "  ·  %.0f%%", share)
                }
                (detail as NSString).draw(
                    with: CGRect(x: inset.minX, y: inset.minY + 15, width: inset.width, height: 13),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: detailAttributes)

                // A folder tile stands for everything inside it; say how much.
                if cell.item.isDirectory, cell.rect.height > 52, cell.rect.width > 110 {
                    let countAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9.5),
                        .foregroundColor: ink.withAlphaComponent(light ? 0.5 : 0.45),
                        .paragraphStyle: paragraph,
                    ].merging(shadow) { current, _ in current }
                    let files = cell.item.fileCount
                    ("\(files.formatted()) file\(files == 1 ? "" : "s")" as NSString).draw(
                        with: CGRect(x: inset.minX, y: inset.minY + 29, width: inset.width, height: 12),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        attributes: countAttributes)
                }
            }
        }
    }

    private var labelShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
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
        guard !isResizing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let cell = layout.item(at: point)
        guard cell?.item !== hovered?.item else { return }
        let previous = hovered?.rect
        hovered = cell
        delegate?.treemap(self, didHover: cell)
        // Only the outgoing and incoming outlines changed.
        if let previous { setNeedsDisplay(previous.insetBy(dx: -2, dy: -2)) }
        if let rect = cell?.rect { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
    }

    override func mouseExited(with event: NSEvent) {
        let previous = hovered?.rect
        hovered = nil
        delegate?.treemap(self, didHover: nil)
        if let previous { setNeedsDisplay(previous.insetBy(dx: -2, dy: -2)) }
    }

    /// Scrolling navigates the hierarchy: scrolling down goes *into* the folder
    /// under the pointer, scrolling up comes back out — the content moves the way
    /// the fingers do, as when scrolling down a page to go deeper into it.
    override func scrollWheel(with event: NSEvent) {
        guard event.deltaY != 0 || event.scrollingDeltaY != 0 else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.deltaY
        scrollAccumulator += delta

        // One step per gesture burst, or a flick crosses several levels at once.
        guard abs(scrollAccumulator) >= 2.5, Date() >= scrollCooldownEnds else { return }
        let goingIn = scrollAccumulator < 0
        scrollAccumulator = 0
        scrollCooldownEnds = Date().addingTimeInterval(0.28)

        if goingIn {
            let point = convert(event.locationInWindow, from: nil)
            guard let cell = layout.item(at: point), cell.item.isDirectory,
                  !cell.item.children.isEmpty else { return }
            hovered = nil
            delegate?.treemap(self, didActivate: cell.item)
        } else {
            hovered = nil
            delegate?.treemapDidRequestUp(self)
        }
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
