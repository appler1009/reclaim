import AppKit

protocol TreemapViewDelegate: AnyObject {
    func treemap(_ view: TreemapView, didHover cell: TreemapCell?)
    func treemap(_ view: TreemapView, didSelect cell: TreemapCell?)
    func treemap(_ view: TreemapView, didActivate item: FileItem)
}

/// Renders a squarified treemap of the scanned tree and handles hit-testing.
/// The map itself is expensive to draw, so it is cached in an image and only
/// hover/selection chrome is redrawn while the pointer moves.
final class TreemapView: NSView {
    weak var delegate: TreemapViewDelegate?

    private(set) var root: FileItem?
    private var layout = TreemapLayout()
    private var cache: NSImage?
    private var generation = 0
    private var hovered: TreemapCell?
    private var selected: FileItem?
    private var trackingArea: NSTrackingArea?

    var measure: SizeMeasure = .physical { didSet { rebuild() } }
    /// Nodes marked for reclamation, with the category that flagged them.
    var wasteMarks: [ObjectIdentifier: WasteCategory] = [:] { didSet { redrawMap() } }
    /// Nodes the user has ticked for deletion.
    var stagedMarks: Set<ObjectIdentifier> = [] { didSet { redrawMap() } }
    /// Dim everything that is not reclaimable.
    var focusWaste = true { didSet { redrawMap() } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(root: FileItem?) {
        self.root = root
        selected = nil
        hovered = nil
        rebuild()
    }

    /// Currently selected node, so SwiftUI can avoid redundant updates.
    var selectedItemIdentity: FileItem? { selected }

    func select(_ item: FileItem?) {
        selected = item
        needsDisplay = true
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    private func rebuild() {
        guard let root, bounds.width > 4, bounds.height > 4 else {
            layout = TreemapLayout(); cache = nil; needsDisplay = true; return
        }
        generation += 1
        let token = generation
        let box = bounds
        let measure = self.measure
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let computed = TreemapLayout.build(root: root, in: box, measure: measure)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.layout = computed
                self.redrawMap()
            }
        }
    }

    private func redrawMap() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(true)
        drawMap()
        image.unlockFocus()
        cache = image
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
        cache?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        drawChrome()
    }

    private func drawMap() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Theme.background.cgColor)
        context.fill(bounds)

        for cell in layout.cells {
            let rect = cell.rect
            guard rect.width > 0.4, rect.height > 0.4 else { continue }
            let waste = wasteCategory(for: cell.item)
            let staged = isStaged(cell.item)

            var color: NSColor
            if let waste {
                color = waste.accent
            } else {
                color = FileFamily.of(cell.item).color
                if focusWaste { color = color.blended(withFraction: 0.74, of: Theme.background) ?? color }
            }
            // Depth shading keeps nested folders legible.
            let shade = min(CGFloat(cell.depth) * 0.045, 0.30)
            color = color.blended(withFraction: shade, of: .black) ?? color
            if staged { color = color.blended(withFraction: 0.35, of: .white) ?? color }

            context.setFillColor(color.cgColor)
            context.fill(rect)

            // Cheap bevel: a bright top-left edge and a dark bottom-right edge.
            if rect.width > 3 && rect.height > 3 {
                context.setFillColor(NSColor(white: 1, alpha: waste != nil ? 0.22 : 0.10).cgColor)
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))
                context.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor)
                context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
                context.fill(CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height))
            }
            if staged && rect.width > 8 && rect.height > 8 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(1.5)
                context.stroke(rect.insetBy(dx: 1, dy: 1))
            }
        }

        // Folder outlines, brightest at the shallowest levels.
        for frame in layout.folderFrames where frame.rect.width > 10 && frame.rect.height > 10 {
            let alpha = max(0.04, 0.30 - CGFloat(frame.depth) * 0.06)
            context.setStrokeColor(NSColor(white: 0, alpha: alpha).cgColor)
            context.setLineWidth(1)
            context.stroke(frame.rect.insetBy(dx: 0.5, dy: 0.5))
        }

        drawLabels()
    }

    private func drawLabels() {
        for cell in layout.cells where cell.rect.width > 74 && cell.rect.height > 22 {
            let waste = wasteCategory(for: cell.item)
            let strong = waste != nil || !focusWaste
            let title = NSMutableParagraphStyle()
            title.lineBreakMode = .byTruncatingMiddle
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(strong ? 0.95 : 0.45),
                .paragraphStyle: title,
                .shadow: labelShadow,
            ]
            let inset = cell.rect.insetBy(dx: 5, dy: 4)
            (cell.item.name as NSString).draw(
                with: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14),
                options: [.truncatesLastVisibleLine], attributes: nameAttributes)

            if cell.rect.height > 40 && cell.rect.width > 110 {
                let detail = ByteFormat.string(cell.item.size(measure))
                    + (waste != nil ? "  ·  reclaimable" : "")
                let detailAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(strong ? 0.72 : 0.32),
                    .paragraphStyle: title,
                    .shadow: labelShadow,
                ]
                (detail as NSString).draw(
                    with: CGRect(x: inset.minX, y: inset.minY + 15, width: inset.width, height: 13),
                    options: [.truncatesLastVisibleLine], attributes: detailAttributes)
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

    // MARK: - Waste lookup

    private func wasteCategory(for item: FileItem) -> WasteCategory? {
        var node: FileItem? = item
        while let current = node {
            if let category = wasteMarks[ObjectIdentifier(current)] { return category }
            node = current.parent
        }
        return nil
    }

    private func isStaged(_ item: FileItem) -> Bool {
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
        let point = convert(event.locationInWindow, from: nil)
        let cell = layout.item(at: point)
        if cell?.item !== hovered?.item {
            hovered = cell
            delegate?.treemap(self, didHover: cell)
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        delegate?.treemap(self, didHover: nil)
        needsDisplay = true
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
