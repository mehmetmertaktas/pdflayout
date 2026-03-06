import AppKit
import UniformTypeIdentifiers
import PDFKit

// ─────────────────────────────────────────────────────────────
// MARK: - Page Size
// ─────────────────────────────────────────────────────────────

enum PageSize: String, CaseIterable {
    case a4     = "A4"
    case letter = "US Letter"
    var width: CGFloat  { self == .a4 ? 595 : 612 }
    var height: CGFloat { self == .a4 ? 842 : 792 }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Canvas Items
// ─────────────────────────────────────────────────────────────

class ImageItem {
    var image: NSImage
    var x: CGFloat
    var y: CGFloat          // continuous: page N starts at N*pageH
    var width: CGFloat
    var height: CGFloat
    var aspectRatio: CGFloat
    var isSelected = false
    var frameColor: NSColor? = nil   // nil = no frame
    var frameWidth: CGFloat = 1
    var opacity: CGFloat = 1.0
    var rotation: CGFloat = 0        // degrees, any angle

    init(image: NSImage, x: CGFloat, y: CGFloat, width: CGFloat) {
        self.image = image
        self.aspectRatio = image.size.width / image.size.height
        self.x = x; self.y = y
        self.width = width
        self.height = width / self.aspectRatio
    }

    func clone(offsetX: CGFloat = 15, offsetY: CGFloat = 15) -> ImageItem {
        let c = ImageItem(image: image, x: x + offsetX, y: y + offsetY, width: width)
        c.height = height; c.aspectRatio = aspectRatio
        c.frameColor = frameColor; c.frameWidth = frameWidth
        c.opacity = opacity; c.rotation = rotation
        return c
    }

    /// Rotate by `degrees` around bounding-box center (no pixel manipulation).
    func rotate(by degrees: CGFloat) {
        rotation = rotation + degrees
        // Normalize to 0..<360
        rotation = rotation.truncatingRemainder(dividingBy: 360)
        if rotation < 0 { rotation += 360 }
    }
}

class TextItem {
    var text: String
    var x: CGFloat
    var y: CGFloat
    var fontSize: CGFloat
    var color: NSColor
    var isBold = false
    var isItalic = false
    var rotation: CGFloat = 0
    var isSelected = false

    init(text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat = 16, color: NSColor = .black) {
        self.text = text; self.x = x; self.y = y
        self.fontSize = fontSize; self.color = color
    }

    func clone(offsetX: CGFloat = 15, offsetY: CGFloat = 15) -> TextItem {
        let c = TextItem(text: text, x: x + offsetX, y: y + offsetY,
                         fontSize: fontSize, color: color)
        c.isBold = isBold; c.isItalic = isItalic; c.rotation = rotation
        return c
    }

    var fontName: String {
        switch (isBold, isItalic) {
        case (true, true):   return "Helvetica-BoldOblique"
        case (true, false):  return "Helvetica-Bold"
        case (false, true):  return "Helvetica-Oblique"
        case (false, false): return "Helvetica"
        }
    }

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    }

    var attrs: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    var size: NSSize { (text as NSString).size(withAttributes: attrs) }
}

class LineItem {
    var x1: CGFloat; var y1: CGFloat
    var x2: CGFloat; var y2: CGFloat
    var color: NSColor
    var lineWidth: CGFloat
    var isSelected = false

    init(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat,
         color: NSColor = .black, lineWidth: CGFloat = 1) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
        self.color = color; self.lineWidth = lineWidth
    }

    func clone(offsetX: CGFloat = 15, offsetY: CGFloat = 15) -> LineItem {
        return LineItem(x1: x1 + offsetX, y1: y1 + offsetY,
                        x2: x2 + offsetX, y2: y2 + offsetY,
                        color: color, lineWidth: lineWidth)
    }

    func hitTest(a4Point p: NSPoint, threshold: CGFloat = 5) -> Bool {
        let dx = x2 - x1, dy = y2 - y1
        let len = hypot(dx, dy)
        guard len > 0.1 else { return hypot(p.x - x1, p.y - y1) < threshold }
        let t = max(0, min(1, ((p.x - x1) * dx + (p.y - y1) * dy) / (len * len)))
        let cx = x1 + t * dx, cy = y1 + t * dy
        return hypot(p.x - cx, p.y - cy) < threshold
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Interaction Mode
// ─────────────────────────────────────────────────────────────

enum InteractionMode {
    case select
    case addText
    case drawLine
}

// ─────────────────────────────────────────────────────────────
// MARK: - Undo Snapshot
// ─────────────────────────────────────────────────────────────

struct UndoSnapshot {
    struct ImgSnap {
        let image: NSImage; let x, y, width, height, aspectRatio, opacity, frameWidth: CGFloat
        let frameColor: NSColor?; let rotation: CGFloat
    }
    struct TxtSnap {
        let text: String; let x, y, fontSize: CGFloat; let color: NSColor
        let isBold: Bool; let isItalic: Bool; let rotation: CGFloat
    }
    struct LnSnap {
        let x1, y1, x2, y2, lineWidth: CGFloat; let color: NSColor
    }
    let images: [ImgSnap]
    let texts: [TxtSnap]
    let lines: [LnSnap]
    let numPages: Int
    let pageSize: PageSize
    let isLandscape: Bool
    let bgColor: NSColor
}

// ─────────────────────────────────────────────────────────────
// MARK: - Snap Guides
// ─────────────────────────────────────────────────────────────

enum GuideAxis { case vertical, horizontal }

struct SnapGuide {
    let axis: GuideAxis
    let a4Pos: CGFloat
    let page: Int
}

struct SnapResult {
    var delta: CGFloat = 0
    var positions: [CGFloat] = []
    var snapped: Bool { !positions.isEmpty }
}

func snapAxis(dragEdges: [CGFloat], targetEdges: [CGFloat], threshold: CGFloat) -> SnapResult {
    var bestDist: CGFloat = .greatestFiniteMagnitude
    var bestDelta: CGFloat = 0
    for de in dragEdges {
        for te in targetEdges {
            let d = abs(te - de)
            if d < bestDist && d <= threshold { bestDist = d; bestDelta = te - de }
        }
    }
    guard bestDist <= threshold else { return SnapResult() }
    let adjusted = dragEdges.map { $0 + bestDelta }
    var positions = Set<CGFloat>()
    for te in targetEdges {
        for ae in adjusted { if abs(te - ae) < 0.5 { positions.insert(te); break } }
    }
    return SnapResult(delta: bestDelta, positions: Array(positions))
}

// ─────────────────────────────────────────────────────────────
// MARK: - Document View
// ─────────────────────────────────────────────────────────────

class DocumentView: NSView, NSTextFieldDelegate {
    var images: [ImageItem] = []
    var texts: [TextItem] = []
    var lines: [LineItem] = []

    var selectedImage: ImageItem?
    var selectedText: TextItem?
    var selectedLine: LineItem?

    var numPages = 1
    var pageSize: PageSize = .a4
    var isLandscape = false
    var bgColor: NSColor = .white
    var showGrid = false
    var zoomLevel: CGFloat = 1.0

    var mode: InteractionMode = .select
    var isDirty = false
    var defaultTextColor: NSColor = .black
    var defaultFontSize: CGFloat = 16
    var onRelayout: (() -> Void)?
    var onDirtyChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?  // called with new zoom level
    var viewportW: CGFloat = 600    // set by relayout, used for page sizing
    var canvasOriginX: CGFloat = 0  // horizontal offset to center content in document
    var canvasOriginY: CGFloat = 0  // vertical offset to center content in document

    // Undo
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private let maxUndo = 50

    // Drag state
    private var isDragging = false
    private var isResizing = false
    private var isDrawingLine = false
    private var dragStartScreen = NSPoint.zero
    private var itemStartPos = NSPoint.zero
    private var itemStartWidth: CGFloat = 0
    private var itemStartHeight: CGFloat = 0
    private var itemStartCenter = NSPoint.zero
    private var lineStartEnd = NSPoint.zero   // second endpoint for line drag
    private var newLineItem: LineItem?
    private var isResizingText = false
    private var itemStartFontSize: CGFloat = 0
    private var isDraggingLineEndpoint = false  // dragging a single endpoint
    private var draggingEndpoint: Int = 0       // 1 = start, 2 = end
    private var resizeCorner: Int = 0  // 0=none, 1=TL, 2=TR, 3=BL, 4=BR
    private var isRotatingWithMouse = false
    private var mouseRotationStartAngle: CGFloat = 0       // radians
    private var mouseRotationItemStartRotation: CGFloat = 0 // degrees (for image/text)
    private var mouseRotLineStart = NSPoint.zero            // line initial endpoints
    private var mouseRotLineEnd = NSPoint.zero

    // Text editing
    private var editingTextField: NSTextField?
    private var editingTextItem: TextItem?

    private var pasteCount = 0
    private var activeGuides: [SnapGuide] = []

    private let handleR: CGFloat = 5
    private let rotHandleOffset: CGFloat = 20
    let pad: CGFloat = 28
    let gap: CGFloat = 24
    private let addBtnSize: CGFloat = 32
    private let snapThreshold: CGFloat = 5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let sp = convert(event.locationInWindow, from: nil)
        switch mode {
        case .addText:
            NSCursor.iBeam.set(); return
        case .drawLine:
            NSCursor.crosshair.set(); return
        case .select:
            break
        }
        // Check rotation handles
        if let item = selectedImage, isOnRotationHandle(screen: sp, item: item) {
            NSCursor.crosshair.set(); return
        }
        if let item = selectedText, isOnTextRotationHandle(screen: sp, item: item) {
            NSCursor.crosshair.set(); return
        }
        if let item = selectedLine, isOnLineRotationHandle(screen: sp, item: item) {
            NSCursor.crosshair.set(); return
        }
        // Check resize handles
        if let item = selectedImage, whichHandle(screen: sp, item: item) != 0 {
            NSCursor.arrow.set()
            return
        }
        if let item = selectedText, whichTextHandle(screen: sp, item: item) != 0 {
            NSCursor.arrow.set()
            return
        }
        if let item = selectedLine, hitLineEndpoint(screen: sp, item: item) != 0 {
            NSCursor.crosshair.set()
            return
        }
        // Check if over any item
        let a4 = toA4(sp)
        if hitText(at: a4) != nil || hitImage(at: a4) != nil || hitLine(at: a4) != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    var PW: CGFloat { isLandscape ? pageSize.height : pageSize.width }
    var PH: CGFloat { isLandscape ? pageSize.width : pageSize.height }

    var pageW: CGFloat { max(100, viewportW - pad * 2) }
    var scale: CGFloat { pageW / PW }
    var pageH: CGFloat { PH * scale }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])

        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        let rotate = NSRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        addGestureRecognizer(rotate)
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── Trackpad gesture state ──
    private var gestureStartWidth: CGFloat = 0
    private var gestureStartHeight: CGFloat = 0
    private var gestureStartFontSize: CGFloat = 0
    private var gestureStartRotation: CGFloat = 0
    private var gestureLineStart = NSPoint.zero
    private var gestureLineEnd = NSPoint.zero
    private var gestureStartZoom: CGFloat = 1.0
    private var isPinchZooming = false

    func totalHeight(forWidth w: CGFloat) -> CGFloat {
        let pw = max(100, w - pad * 2)
        let ph = PH * (pw / PW)
        return pad + CGFloat(numPages) * ph + CGFloat(max(0, numPages - 1)) * gap + pad + addBtnSize + 24
    }

    func pageRect(for i: Int) -> NSRect {
        NSRect(x: canvasOriginX + pad, y: canvasOriginY + pad + CGFloat(i) * (pageH + gap), width: pageW, height: pageH)
    }

    var addButtonRect: NSRect {
        let lastPage = pageRect(for: numPages - 1)
        let btnY = lastPage.maxY + gap * 0.5
        let btnX = canvasOriginX + pad + pageW / 2 - addBtnSize / 2
        return NSRect(x: btnX, y: btnY, width: addBtnSize, height: addBtnSize)
    }

    // ── Coordinate conversion ──

    func toA4(_ sp: NSPoint) -> NSPoint {
        for i in 0..<numPages {
            let r = pageRect(for: i)
            if sp.y < r.maxY + gap / 2 || i == numPages - 1 {
                let lx = (sp.x - r.minX) / scale
                let ly = (sp.y - r.minY) / scale
                return NSPoint(x: lx, y: CGFloat(i) * PH + ly)
            }
        }
        return .zero
    }

    func toScreen(_ a4: NSPoint) -> NSPoint {
        let pg = min(max(0, Int(a4.y / PH)), numPages - 1)
        let ly = a4.y - CGFloat(pg) * PH
        let r = pageRect(for: pg)
        return NSPoint(x: r.minX + a4.x * scale, y: r.minY + ly * scale)
    }

    func screenFrame(for item: ImageItem) -> NSRect {
        let o = toScreen(NSPoint(x: item.x, y: item.y))
        return NSRect(x: o.x, y: o.y, width: item.width * scale, height: item.height * scale)
    }

    func screenFrame(for item: TextItem) -> NSRect {
        let o = toScreen(NSPoint(x: item.x, y: item.y))
        let sz = item.size
        return NSRect(x: o.x, y: o.y, width: sz.width * scale, height: sz.height * scale)
    }

    // ── Undo / Redo ──

    func pushUndo() {
        let snap = UndoSnapshot(
            images: images.map { .init(image: $0.image, x: $0.x, y: $0.y, width: $0.width,
                                        height: $0.height, aspectRatio: $0.aspectRatio,
                                        opacity: $0.opacity, frameWidth: $0.frameWidth,
                                        frameColor: $0.frameColor, rotation: $0.rotation) },
            texts: texts.map { .init(text: $0.text, x: $0.x, y: $0.y,
                                      fontSize: $0.fontSize, color: $0.color,
                                      isBold: $0.isBold, isItalic: $0.isItalic, rotation: $0.rotation) },
            lines: lines.map { .init(x1: $0.x1, y1: $0.y1, x2: $0.x2, y2: $0.y2,
                                      lineWidth: $0.lineWidth, color: $0.color) },
            numPages: numPages, pageSize: pageSize, isLandscape: isLandscape, bgColor: bgColor
        )
        undoStack.append(snap)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restoreSnapshot(_ snap: UndoSnapshot) {
        deselectAll()
        images = snap.images.map { s in
            let it = ImageItem(image: s.image, x: s.x, y: s.y, width: s.width)
            it.height = s.height; it.aspectRatio = s.aspectRatio
            it.opacity = s.opacity; it.frameWidth = s.frameWidth
            it.frameColor = s.frameColor; it.rotation = s.rotation
            return it
        }
        texts = snap.texts.map { s in
            let t = TextItem(text: s.text, x: s.x, y: s.y, fontSize: s.fontSize, color: s.color)
            t.isBold = s.isBold; t.isItalic = s.isItalic; t.rotation = s.rotation
            return t
        }
        lines = snap.lines.map { LineItem(x1: $0.x1, y1: $0.y1, x2: $0.x2, y2: $0.y2,
                                            color: $0.color, lineWidth: $0.lineWidth) }
        numPages = snap.numPages; pageSize = snap.pageSize; isLandscape = snap.isLandscape; bgColor = snap.bgColor
        markDirty()
        onRelayout?()
        needsDisplay = true
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        // Push current state to redo
        let cur = UndoSnapshot(
            images: images.map { .init(image: $0.image, x: $0.x, y: $0.y, width: $0.width,
                                        height: $0.height, aspectRatio: $0.aspectRatio,
                                        opacity: $0.opacity, frameWidth: $0.frameWidth,
                                        frameColor: $0.frameColor, rotation: $0.rotation) },
            texts: texts.map { .init(text: $0.text, x: $0.x, y: $0.y,
                                      fontSize: $0.fontSize, color: $0.color,
                                      isBold: $0.isBold, isItalic: $0.isItalic, rotation: $0.rotation) },
            lines: lines.map { .init(x1: $0.x1, y1: $0.y1, x2: $0.x2, y2: $0.y2,
                                      lineWidth: $0.lineWidth, color: $0.color) },
            numPages: numPages, pageSize: pageSize, isLandscape: isLandscape, bgColor: bgColor
        )
        redoStack.append(cur)
        restoreSnapshot(snap)
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        let cur = UndoSnapshot(
            images: images.map { .init(image: $0.image, x: $0.x, y: $0.y, width: $0.width,
                                        height: $0.height, aspectRatio: $0.aspectRatio,
                                        opacity: $0.opacity, frameWidth: $0.frameWidth,
                                        frameColor: $0.frameColor, rotation: $0.rotation) },
            texts: texts.map { .init(text: $0.text, x: $0.x, y: $0.y,
                                      fontSize: $0.fontSize, color: $0.color,
                                      isBold: $0.isBold, isItalic: $0.isItalic, rotation: $0.rotation) },
            lines: lines.map { .init(x1: $0.x1, y1: $0.y1, x2: $0.x2, y2: $0.y2,
                                      lineWidth: $0.lineWidth, color: $0.color) },
            numPages: numPages, pageSize: pageSize, isLandscape: isLandscape, bgColor: bgColor
        )
        undoStack.append(cur)
        restoreSnapshot(snap)
    }

    // ── Dirty ──

    func markDirty() {
        isDirty = true
        onDirtyChanged?()
    }

    func clearDirty() {
        isDirty = false
        onDirtyChanged?()
    }

    // ── Selection ──

    func deselectAll() {
        selectedImage?.isSelected = false; selectedImage = nil
        selectedText?.isSelected = false; selectedText = nil
        selectedLine?.isSelected = false; selectedLine = nil
        activeGuides = []
        onSelectionChanged?()
    }

    func selectImage(_ item: ImageItem?) {
        deselectAll()
        selectedImage = item
        item?.isSelected = true
        onSelectionChanged?()
        needsDisplay = true
    }

    func selectText(_ item: TextItem?) {
        deselectAll()
        selectedText = item
        item?.isSelected = true
        onSelectionChanged?()
        needsDisplay = true
    }

    func selectLine(_ item: LineItem?) {
        deselectAll()
        selectedLine = item
        item?.isSelected = true
        onSelectionChanged?()
        needsDisplay = true
    }

    // ── Snap computation ──

    let guideColor = NSColor(red: 1, green: 0.22, blue: 0.38, alpha: 0.85)

    func computeSnaps(for item: ImageItem) -> (dx: CGFloat, dy: CGFloat, guides: [SnapGuide]) {
        let page = min(max(0, Int(item.y / PH)), numPages - 1)
        let localY = item.y - CGFloat(page) * PH
        let dxEdges = [item.x, item.x + item.width / 2, item.x + item.width]
        let dyEdges = [localY, localY + item.height / 2, localY + item.height]
        var txEdges: [CGFloat] = [0, PW / 2, PW]
        var tyEdges: [CGFloat] = [0, PH / 2, PH]
        for other in images where other !== item {
            let op = min(max(0, Int(other.y / PH)), numPages - 1)
            guard op == page else { continue }
            let oly = other.y - CGFloat(op) * PH
            txEdges.append(contentsOf: [other.x, other.x + other.width / 2, other.x + other.width])
            tyEdges.append(contentsOf: [oly, oly + other.height / 2, oly + other.height])
        }
        let sx = snapAxis(dragEdges: dxEdges, targetEdges: txEdges, threshold: snapThreshold)
        let sy = snapAxis(dragEdges: dyEdges, targetEdges: tyEdges, threshold: snapThreshold)
        var guides: [SnapGuide] = []
        for pos in sx.positions { guides.append(SnapGuide(axis: .vertical, a4Pos: pos, page: page)) }
        for pos in sy.positions { guides.append(SnapGuide(axis: .horizontal, a4Pos: pos, page: page)) }
        return (sx.snapped ? sx.delta : 0, sy.snapped ? sy.delta : 0, guides)
    }

    func computeTextSnaps(for item: TextItem) -> (dx: CGFloat, dy: CGFloat, guides: [SnapGuide]) {
        let sz = item.size
        let page = min(max(0, Int(item.y / PH)), numPages - 1)
        let localY = item.y - CGFloat(page) * PH
        let dxEdges = [item.x, item.x + sz.width / 2, item.x + sz.width]
        let dyEdges = [localY, localY + sz.height / 2, localY + sz.height]
        var txEdges: [CGFloat] = [0, PW / 2, PW]
        var tyEdges: [CGFloat] = [0, PH / 2, PH]
        for img in images {
            let op = min(max(0, Int(img.y / PH)), numPages - 1)
            guard op == page else { continue }
            let oly = img.y - CGFloat(op) * PH
            txEdges.append(contentsOf: [img.x, img.x + img.width / 2, img.x + img.width])
            tyEdges.append(contentsOf: [oly, oly + img.height / 2, oly + img.height])
        }
        for other in texts where other !== item {
            let op = min(max(0, Int(other.y / PH)), numPages - 1)
            guard op == page else { continue }
            let oly = other.y - CGFloat(op) * PH
            let osz = other.size
            txEdges.append(contentsOf: [other.x, other.x + osz.width / 2, other.x + osz.width])
            tyEdges.append(contentsOf: [oly, oly + osz.height / 2, oly + osz.height])
        }
        let sx = snapAxis(dragEdges: dxEdges, targetEdges: txEdges, threshold: snapThreshold)
        let sy = snapAxis(dragEdges: dyEdges, targetEdges: tyEdges, threshold: snapThreshold)
        var guides: [SnapGuide] = []
        for pos in sx.positions { guides.append(SnapGuide(axis: .vertical, a4Pos: pos, page: page)) }
        for pos in sy.positions { guides.append(SnapGuide(axis: .horizontal, a4Pos: pos, page: page)) }
        return (sx.snapped ? sx.delta : 0, sy.snapped ? sy.delta : 0, guides)
    }

    // ── Drawing ──

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.91, alpha: 1).setFill()
        dirtyRect.fill()

        for i in 0..<numPages {
            let r = pageRect(for: i)
            guard dirtyRect.intersects(r.insetBy(dx: -16, dy: -16)) else { continue }

            // Shadow + page bg
            NSGraphicsContext.saveGraphicsState()
            let shd = NSShadow()
            shd.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shd.shadowOffset = NSSize(width: 0, height: -1)
            shd.shadowBlurRadius = 8
            shd.set()
            bgColor.setFill()
            r.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Clip to page
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).setClip()

            // Grid overlay (before items)
            if showGrid {
                let gridSpacing: CGFloat = 50  // A4 points
                NSColor(white: 0.60, alpha: 0.50).setStroke()
                let gp = NSBezierPath()
                gp.lineWidth = 0.5
                let pattern: [CGFloat] = [6, 3]
                gp.setLineDash(pattern, count: 2, phase: 0)
                var gx: CGFloat = gridSpacing
                while gx < PW {
                    let sx = r.minX + gx * scale
                    gp.move(to: NSPoint(x: sx, y: r.minY))
                    gp.line(to: NSPoint(x: sx, y: r.maxY))
                    gx += gridSpacing
                }
                var gy: CGFloat = gridSpacing
                while gy < PH {
                    let sy = r.minY + gy * scale
                    gp.move(to: NSPoint(x: r.minX, y: sy))
                    gp.line(to: NSPoint(x: r.maxX, y: sy))
                    gy += gridSpacing
                }
                gp.stroke()
            }

            // Hint on first page when empty
            if i == 0 && images.isEmpty && texts.isEmpty && lines.isEmpty {
                let hintAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor(white: 0.72, alpha: 1),
                    .font: NSFont.systemFont(ofSize: 15, weight: .light)
                ]
                let hintText = "Paste an image  \u{2318}V  or drag from Finder" as NSString
                let sz = hintText.size(withAttributes: hintAttrs)
                hintText.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2),
                              withAttributes: hintAttrs)
            }

            let pageTop = CGFloat(i) * PH
            let pageBot = pageTop + PH

            // Draw lines (skip selected if dragging — drawn on top later)
            for item in lines {
                if isDragging && item === selectedLine { continue }
                let minY = min(item.y1, item.y2), maxY = max(item.y1, item.y2)
                guard maxY > pageTop && minY < pageBot else { continue }
                let p1 = toScreen(NSPoint(x: item.x1, y: item.y1))
                let p2 = toScreen(NSPoint(x: item.x2, y: item.y2))
                item.color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = item.lineWidth * scale
                path.move(to: p1); path.line(to: p2)
                path.stroke()

                if item.isSelected {
                    NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
                    let selPath = NSBezierPath()
                    selPath.lineWidth = max(1, item.lineWidth * scale + 2)
                    selPath.move(to: p1); selPath.line(to: p2)
                    selPath.stroke()
                    // Endpoint handles (larger, with white inner)
                    for ep in [p1, p2] {
                        let dr: CGFloat = 5
                        let ov = NSRect(x: ep.x - dr, y: ep.y - dr, width: dr * 2, height: dr * 2)
                        NSColor.controlAccentColor.setFill()
                        NSBezierPath(ovalIn: ov).fill()
                        NSColor.white.setFill()
                        NSBezierPath(ovalIn: ov.insetBy(dx: 1.5, dy: 1.5)).fill()
                    }
                    // Rotation handle (perpendicular from midpoint, green)
                    let mid = NSPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                    let lineDx = p2.x - p1.x, lineDy = p2.y - p1.y
                    let lineLen = hypot(lineDx, lineDy)
                    if lineLen > 1 {
                        let perpX = -lineDy / lineLen, perpY = lineDx / lineLen
                        let lsign: CGFloat = perpY < 0 ? 1.0 : -1.0
                        let lrhCenter = NSPoint(x: mid.x + lsign * perpX * rotHandleOffset,
                                                 y: mid.y + lsign * perpY * rotHandleOffset)
                        NSColor.systemGreen.withAlphaComponent(0.7).setStroke()
                        let lStemPath = NSBezierPath()
                        lStemPath.lineWidth = 1
                        lStemPath.move(to: mid)
                        lStemPath.line(to: lrhCenter)
                        lStemPath.stroke()
                        let lrhOv = NSRect(x: lrhCenter.x - handleR, y: lrhCenter.y - handleR,
                                            width: handleR * 2, height: handleR * 2)
                        NSColor.systemGreen.setFill()
                        NSBezierPath(ovalIn: lrhOv).fill()
                        NSColor.white.setFill()
                        NSBezierPath(ovalIn: lrhOv.insetBy(dx: 1.5, dy: 1.5)).fill()
                        NSColor.systemGreen.setStroke()
                        let lArcPath = NSBezierPath()
                        lArcPath.lineWidth = 1.0
                        lArcPath.appendArc(withCenter: lrhCenter, radius: handleR - 1,
                                            startAngle: 30, endAngle: 300, clockwise: true)
                        lArcPath.stroke()
                    }
                    // Rotation angle badge at midpoint
                    var angleDeg = atan2(item.y2 - item.y1, item.x2 - item.x1) * 180 / .pi
                    if angleDeg < 0 { angleDeg += 360 }
                    // Normalize to nearest display angle
                    let displayAngle = abs(angleDeg) < 0.5 || abs(angleDeg - 360) < 0.5 ? 0 : angleDeg
                    let label = String(format: "%.1f°", displayAngle) as NSString
                    let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
                    let badgeAttrs: [NSAttributedString.Key: Any] = [
                        .font: badgeFont,
                        .foregroundColor: NSColor.white
                    ]
                    let labelSz = label.size(withAttributes: badgeAttrs)
                    let badgePad: CGFloat = 3
                    let badgeRect = NSRect(x: mid.x - labelSz.width / 2 - badgePad,
                                           y: mid.y - labelSz.height - 10,
                                           width: labelSz.width + badgePad * 2,
                                           height: labelSz.height + badgePad)
                    NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3).fill()
                    label.draw(at: NSPoint(x: badgeRect.minX + badgePad,
                                           y: badgeRect.minY + badgePad / 2),
                               withAttributes: badgeAttrs)
                }
            }

            // Draw images (skip selected if dragging — drawn on top later)
            for item in images {
                if isDragging && item === selectedImage { continue }
                guard item.y + item.height > pageTop && item.y < pageBot else { continue }
                let f = screenFrame(for: item)

                // Apply rotation transform around center
                let cx = f.midX, cy = f.midY
                let hasRotation = abs(item.rotation) > 0.01
                if hasRotation {
                    NSGraphicsContext.saveGraphicsState()
                    let rot = NSAffineTransform()
                    rot.translateX(by: cx, yBy: cy)
                    rot.rotate(byDegrees: -item.rotation)  // negative for CW in flipped
                    rot.translateX(by: -cx, yBy: -cy)
                    rot.concat()
                }

                item.image.draw(in: f, from: NSRect(origin: .zero, size: item.image.size),
                                operation: .sourceOver, fraction: item.opacity,
                                respectFlipped: true, hints: nil)

                if let fc = item.frameColor {
                    fc.setStroke()
                    let bezel = NSBezierPath(rect: f)
                    bezel.lineWidth = max(0.5, item.frameWidth * scale)
                    bezel.stroke()
                }

                if item.isSelected {
                    // Draw selection border inside rotation transform so it rotates with the image
                    NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
                    let border = NSBezierPath(rect: f.insetBy(dx: -1, dy: -1))
                    border.lineWidth = 1.5
                    let dashPattern: [CGFloat] = [4, 4]
                    border.setLineDash(dashPattern, count: 2, phase: 0)
                    border.stroke()
                    // Resize handles (all four corners)
                    for corner in [NSPoint(x: f.minX, y: f.minY), NSPoint(x: f.maxX, y: f.minY),
                                   NSPoint(x: f.minX, y: f.maxY), NSPoint(x: f.maxX, y: f.maxY)] {
                        let ov = NSRect(x: corner.x - handleR, y: corner.y - handleR,
                                        width: handleR * 2, height: handleR * 2)
                        NSColor.controlAccentColor.setFill()
                        NSBezierPath(ovalIn: ov).fill()
                        NSColor.white.setFill()
                        NSBezierPath(ovalIn: ov.insetBy(dx: 1.5, dy: 1.5)).fill()
                    }
                    // Rotation handle (top-center, green)
                    let rhCenter = NSPoint(x: f.midX, y: f.minY - rotHandleOffset)
                    NSColor.systemGreen.withAlphaComponent(0.7).setStroke()
                    let stemPath = NSBezierPath()
                    stemPath.lineWidth = 1
                    stemPath.move(to: NSPoint(x: f.midX, y: f.minY))
                    stemPath.line(to: rhCenter)
                    stemPath.stroke()
                    let rhOv = NSRect(x: rhCenter.x - handleR, y: rhCenter.y - handleR,
                                      width: handleR * 2, height: handleR * 2)
                    NSColor.systemGreen.setFill()
                    NSBezierPath(ovalIn: rhOv).fill()
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: rhOv.insetBy(dx: 1.5, dy: 1.5)).fill()
                    NSColor.systemGreen.setStroke()
                    let arcPath = NSBezierPath()
                    arcPath.lineWidth = 1.0
                    arcPath.appendArc(withCenter: rhCenter, radius: handleR - 1,
                                       startAngle: 30, endAngle: 300, clockwise: true)
                    arcPath.stroke()
                    // Rotation angle badge (only when rotated)
                    if hasRotation {
                        let displayAngle = abs(item.rotation) < 0.5 || abs(item.rotation - 360) < 0.5 ? 0 : item.rotation
                        let label = String(format: "%.1f°", displayAngle) as NSString
                        let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
                        let badgeAttrs: [NSAttributedString.Key: Any] = [
                            .font: badgeFont,
                            .foregroundColor: NSColor.white
                        ]
                        let labelSz = label.size(withAttributes: badgeAttrs)
                        let badgePad: CGFloat = 3
                        let badgeRect = NSRect(x: f.midX - labelSz.width / 2 - badgePad,
                                               y: f.minY - labelSz.height - badgePad - 10 - rotHandleOffset,
                                               width: labelSz.width + badgePad * 2,
                                               height: labelSz.height + badgePad)
                        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                        NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3).fill()
                        label.draw(at: NSPoint(x: badgeRect.minX + badgePad,
                                               y: badgeRect.minY + badgePad / 2),
                                   withAttributes: badgeAttrs)
                    }
                }

                if hasRotation {
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            // Draw texts (skip selected if dragging — drawn on top later)
            for item in texts {
                if isDragging && item === selectedText { continue }
                let sz = item.size
                guard item.y + sz.height > pageTop && item.y < pageBot else { continue }
                let o = toScreen(NSPoint(x: item.x, y: item.y))
                let drawRect = NSRect(x: o.x, y: o.y, width: sz.width * scale, height: sz.height * scale)

                // Apply rotation transform around text center
                let tcx = drawRect.midX, tcy = drawRect.midY
                let hasTextRotation = abs(item.rotation) > 0.01
                if hasTextRotation {
                    NSGraphicsContext.saveGraphicsState()
                    let rot = NSAffineTransform()
                    rot.translateX(by: tcx, yBy: tcy)
                    rot.rotate(byDegrees: -item.rotation)
                    rot.translateX(by: -tcx, yBy: -tcy)
                    rot.concat()
                }

                // Scale the font for screen rendering
                let scaledFont = NSFont(name: item.fontName, size: item.fontSize * scale)
                    ?? NSFont.systemFont(ofSize: item.fontSize * scale)
                let scaledAttrs: [NSAttributedString.Key: Any] = [
                    .font: scaledFont,
                    .foregroundColor: item.color
                ]
                (item.text as NSString).draw(at: NSPoint(x: o.x, y: o.y), withAttributes: scaledAttrs)

                if item.isSelected {
                    NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                    let border = NSBezierPath(rect: drawRect.insetBy(dx: -2, dy: -2))
                    border.lineWidth = 1
                    let dashPattern: [CGFloat] = [3, 3]
                    border.setLineDash(dashPattern, count: 2, phase: 0)
                    border.stroke()
                    // Resize handles (all four corners)
                    for corner in [NSPoint(x: drawRect.minX, y: drawRect.minY), NSPoint(x: drawRect.maxX, y: drawRect.minY),
                                   NSPoint(x: drawRect.minX, y: drawRect.maxY), NSPoint(x: drawRect.maxX, y: drawRect.maxY)] {
                        let tov = NSRect(x: corner.x - handleR, y: corner.y - handleR,
                                         width: handleR * 2, height: handleR * 2)
                        NSColor.controlAccentColor.setFill()
                        NSBezierPath(ovalIn: tov).fill()
                        NSColor.white.setFill()
                        NSBezierPath(ovalIn: tov.insetBy(dx: 1.5, dy: 1.5)).fill()
                    }
                    // Rotation handle (top-center, green)
                    let trhCenter = NSPoint(x: drawRect.midX, y: drawRect.minY - rotHandleOffset)
                    NSColor.systemGreen.withAlphaComponent(0.7).setStroke()
                    let tStemPath = NSBezierPath()
                    tStemPath.lineWidth = 1
                    tStemPath.move(to: NSPoint(x: drawRect.midX, y: drawRect.minY))
                    tStemPath.line(to: trhCenter)
                    tStemPath.stroke()
                    let trhOv = NSRect(x: trhCenter.x - handleR, y: trhCenter.y - handleR,
                                        width: handleR * 2, height: handleR * 2)
                    NSColor.systemGreen.setFill()
                    NSBezierPath(ovalIn: trhOv).fill()
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: trhOv.insetBy(dx: 1.5, dy: 1.5)).fill()
                    NSColor.systemGreen.setStroke()
                    let tArcPath = NSBezierPath()
                    tArcPath.lineWidth = 1.0
                    tArcPath.appendArc(withCenter: trhCenter, radius: handleR - 1,
                                        startAngle: 30, endAngle: 300, clockwise: true)
                    tArcPath.stroke()
                }

                if hasTextRotation {
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            // Draw selected item on top when dragging (z-boost)
            if isDragging {
                if let item = selectedLine {
                    let minY = min(item.y1, item.y2), maxY = max(item.y1, item.y2)
                    if maxY > pageTop && minY < pageBot {
                        let p1 = toScreen(NSPoint(x: item.x1, y: item.y1))
                        let p2 = toScreen(NSPoint(x: item.x2, y: item.y2))
                        item.color.setStroke()
                        let path = NSBezierPath()
                        path.lineWidth = item.lineWidth * scale
                        path.move(to: p1); path.line(to: p2)
                        path.stroke()
                        if item.isSelected {
                            NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
                            let selPath = NSBezierPath()
                            selPath.lineWidth = max(1, item.lineWidth * scale + 2)
                            selPath.move(to: p1); selPath.line(to: p2)
                            selPath.stroke()
                        }
                    }
                }
                if let item = selectedImage {
                    if item.y + item.height > pageTop && item.y < pageBot {
                        let f = screenFrame(for: item)
                        let cx = f.midX, cy = f.midY
                        let hasRotation = abs(item.rotation) > 0.01
                        if hasRotation {
                            NSGraphicsContext.saveGraphicsState()
                            let rot = NSAffineTransform()
                            rot.translateX(by: cx, yBy: cy)
                            rot.rotate(byDegrees: -item.rotation)
                            rot.translateX(by: -cx, yBy: -cy)
                            rot.concat()
                        }
                        item.image.draw(in: f, from: NSRect(origin: .zero, size: item.image.size),
                                        operation: .sourceOver, fraction: item.opacity,
                                        respectFlipped: true, hints: nil)
                        if let fc = item.frameColor {
                            fc.setStroke()
                            let bezel = NSBezierPath(rect: f)
                            bezel.lineWidth = max(0.5, item.frameWidth * scale)
                            bezel.stroke()
                        }
                        if item.isSelected {
                            NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
                            let border = NSBezierPath(rect: f.insetBy(dx: -1, dy: -1))
                            border.lineWidth = 1.5
                            let dashPattern: [CGFloat] = [4, 4]
                            border.setLineDash(dashPattern, count: 2, phase: 0)
                            border.stroke()
                        }
                        if hasRotation { NSGraphicsContext.restoreGraphicsState() }
                    }
                }
                if let item = selectedText {
                    let sz = item.size
                    if item.y + sz.height > pageTop && item.y < pageBot {
                        let o = toScreen(NSPoint(x: item.x, y: item.y))
                        let drawRect = NSRect(x: o.x, y: o.y, width: sz.width * scale, height: sz.height * scale)
                        let hasTextRotation = abs(item.rotation) > 0.01
                        if hasTextRotation {
                            NSGraphicsContext.saveGraphicsState()
                            let rot = NSAffineTransform()
                            rot.translateX(by: drawRect.midX, yBy: drawRect.midY)
                            rot.rotate(byDegrees: -item.rotation)
                            rot.translateX(by: -drawRect.midX, yBy: -drawRect.midY)
                            rot.concat()
                        }
                        let scaledFont = NSFont(name: item.fontName, size: item.fontSize * scale)
                            ?? NSFont.systemFont(ofSize: item.fontSize * scale)
                        let scaledAttrs: [NSAttributedString.Key: Any] = [
                            .font: scaledFont, .foregroundColor: item.color
                        ]
                        (item.text as NSString).draw(at: NSPoint(x: o.x, y: o.y), withAttributes: scaledAttrs)
                        if item.isSelected {
                            NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                            let border = NSBezierPath(rect: drawRect.insetBy(dx: -2, dy: -2))
                            border.lineWidth = 1
                            let dashPattern: [CGFloat] = [3, 3]
                            border.setLineDash(dashPattern, count: 2, phase: 0)
                            border.stroke()
                        }
                        if hasTextRotation { NSGraphicsContext.restoreGraphicsState() }
                    }
                }
            }

            // Snap guide lines
            for guide in activeGuides where guide.page == i {
                guideColor.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 0.75
                if guide.axis == .vertical {
                    let sx = r.minX + guide.a4Pos * scale
                    path.move(to: NSPoint(x: sx, y: r.minY))
                    path.line(to: NSPoint(x: sx, y: r.maxY))
                } else {
                    let sy = r.minY + guide.a4Pos * scale
                    path.move(to: NSPoint(x: r.minX, y: sy))
                    path.line(to: NSPoint(x: r.maxX, y: sy))
                }
                path.stroke()
            }

            // Page number
            let num = "\(i + 1)" as NSString
            let numAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(white: 0.78, alpha: 1),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            ]
            let nsz = num.size(withAttributes: numAttrs)
            num.draw(at: NSPoint(x: r.midX - nsz.width / 2, y: r.maxY - nsz.height - 8),
                     withAttributes: numAttrs)

            NSGraphicsContext.restoreGraphicsState()
        }

        // "+" button
        let btnR = addButtonRect
        if dirtyRect.intersects(btnR.insetBy(dx: -8, dy: -8)) {
            NSColor(white: 0.82, alpha: 1).setStroke()
            let circle = NSBezierPath(ovalIn: btnR.insetBy(dx: 2, dy: 2))
            circle.lineWidth = 1.5; circle.stroke()
            let plus = "+" as NSString
            let pAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(white: 0.62, alpha: 1),
                .font: NSFont.systemFont(ofSize: 18, weight: .light)
            ]
            let psz = plus.size(withAttributes: pAttrs)
            plus.draw(at: NSPoint(x: btnR.midX - psz.width / 2, y: btnR.midY - psz.height / 2),
                      withAttributes: pAttrs)
        }

        // Line being drawn
        if isDrawingLine, let nl = newLineItem {
            let p1 = toScreen(NSPoint(x: nl.x1, y: nl.y1))
            let p2 = toScreen(NSPoint(x: nl.x2, y: nl.y2))
            nl.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = nl.lineWidth * scale
            path.move(to: p1); path.line(to: p2)
            path.stroke()
        }
    }

    // ── Hit testing ──

    private func hitImage(at a4: NSPoint) -> ImageItem? {
        for item in images.reversed() {
            if NSRect(x: item.x, y: item.y, width: item.width, height: item.height).contains(a4) {
                return item
            }
        }
        return nil
    }

    private func hitText(at a4: NSPoint) -> TextItem? {
        for item in texts.reversed() {
            let sz = item.size
            if NSRect(x: item.x, y: item.y, width: sz.width, height: sz.height).contains(a4) {
                return item
            }
        }
        return nil
    }

    private func hitLine(at a4: NSPoint) -> LineItem? {
        for item in lines.reversed() {
            if item.hitTest(a4Point: a4) { return item }
        }
        return nil
    }

    /// Returns corner ID: 0=none, 1=TL, 2=TR, 3=BL, 4=BR
    private func whichHandle(screen sp: NSPoint, item: ImageItem) -> Int {
        let f = screenFrame(for: item)
        let corners: [(NSPoint, Int)] = [
            (NSPoint(x: f.minX, y: f.minY), 1), (NSPoint(x: f.maxX, y: f.minY), 2),
            (NSPoint(x: f.minX, y: f.maxY), 3), (NSPoint(x: f.maxX, y: f.maxY), 4),
        ]
        let threshold = handleR + 6
        if abs(item.rotation) > 0.01 {
            let cx = f.midX, cy = f.midY
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: cy)
            t.rotate(byDegrees: -item.rotation)
            t.translateX(by: -cx, yBy: -cy)
            for (pt, id) in corners {
                if hypot(sp.x - t.transform(pt).x, sp.y - t.transform(pt).y) < threshold { return id }
            }
        } else {
            for (pt, id) in corners {
                if hypot(sp.x - pt.x, sp.y - pt.y) < threshold { return id }
            }
        }
        return 0
    }

    /// Returns corner ID: 0=none, 1=TL, 2=TR, 3=BL, 4=BR
    private func whichTextHandle(screen sp: NSPoint, item: TextItem) -> Int {
        let f = screenFrame(for: item)
        let corners: [(NSPoint, Int)] = [
            (NSPoint(x: f.minX, y: f.minY), 1), (NSPoint(x: f.maxX, y: f.minY), 2),
            (NSPoint(x: f.minX, y: f.maxY), 3), (NSPoint(x: f.maxX, y: f.maxY), 4),
        ]
        let threshold = handleR + 6
        if abs(item.rotation) > 0.01 {
            let cx = f.midX, cy = f.midY
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: cy)
            t.rotate(byDegrees: -item.rotation)
            t.translateX(by: -cx, yBy: -cy)
            for (pt, id) in corners {
                if hypot(sp.x - t.transform(pt).x, sp.y - t.transform(pt).y) < threshold { return id }
            }
        } else {
            for (pt, id) in corners {
                if hypot(sp.x - pt.x, sp.y - pt.y) < threshold { return id }
            }
        }
        return 0
    }

    /// Returns 1 if near start endpoint, 2 if near end endpoint, 0 if neither.
    private func hitLineEndpoint(screen sp: NSPoint, item: LineItem) -> Int {
        let p1 = toScreen(NSPoint(x: item.x1, y: item.y1))
        let p2 = toScreen(NSPoint(x: item.x2, y: item.y2))
        if hypot(sp.x - p1.x, sp.y - p1.y) < handleR + 6 { return 1 }
        if hypot(sp.x - p2.x, sp.y - p2.y) < handleR + 6 { return 2 }
        return 0
    }

    private func isOnRotationHandle(screen sp: NSPoint, item: ImageItem) -> Bool {
        let f = screenFrame(for: item)
        let handlePt = NSPoint(x: f.midX, y: f.minY - rotHandleOffset)
        if abs(item.rotation) > 0.01 {
            let cx = f.midX, cy = f.midY
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: cy)
            t.rotate(byDegrees: -item.rotation)
            t.translateX(by: -cx, yBy: -cy)
            let rh = t.transform(handlePt)
            return hypot(sp.x - rh.x, sp.y - rh.y) < handleR + 6
        }
        return hypot(sp.x - handlePt.x, sp.y - handlePt.y) < handleR + 6
    }

    private func isOnTextRotationHandle(screen sp: NSPoint, item: TextItem) -> Bool {
        let f = screenFrame(for: item)
        let handlePt = NSPoint(x: f.midX, y: f.minY - rotHandleOffset)
        if abs(item.rotation) > 0.01 {
            let cx = f.midX, cy = f.midY
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: cy)
            t.rotate(byDegrees: -item.rotation)
            t.translateX(by: -cx, yBy: -cy)
            let rh = t.transform(handlePt)
            return hypot(sp.x - rh.x, sp.y - rh.y) < handleR + 6
        }
        return hypot(sp.x - handlePt.x, sp.y - handlePt.y) < handleR + 6
    }

    private func isOnLineRotationHandle(screen sp: NSPoint, item: LineItem) -> Bool {
        let p1 = toScreen(NSPoint(x: item.x1, y: item.y1))
        let p2 = toScreen(NSPoint(x: item.x2, y: item.y2))
        let mid = NSPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        let ldx = p2.x - p1.x, ldy = p2.y - p1.y
        let len = hypot(ldx, ldy)
        guard len > 1 else { return false }
        let perpX = -ldy / len, perpY = ldx / len
        let sign: CGFloat = perpY < 0 ? 1.0 : -1.0
        let handlePt = NSPoint(x: mid.x + sign * perpX * rotHandleOffset,
                               y: mid.y + sign * perpY * rotHandleOffset)
        return hypot(sp.x - handlePt.x, sp.y - handlePt.y) < handleR + 6
    }

    // ── Mouse events ──

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let sp = convert(event.locationInWindow, from: nil)

        // "+" button
        if addButtonRect.insetBy(dx: -4, dy: -4).contains(sp) {
            pushUndo(); addPage(); onRelayout?()
            DispatchQueue.main.async { [self] in scrollToVisible(pageRect(for: numPages - 1)) }
            return
        }

        let a4 = toA4(sp)

        switch mode {
        case .addText:
            pushUndo()
            let item = TextItem(text: "Text", x: a4.x, y: a4.y,
                                  fontSize: defaultFontSize, color: defaultTextColor)
            texts.append(item)
            selectText(item)
            markDirty()
            mode = .select
            // Start editing immediately
            beginTextEditing(item)
            return

        case .drawLine:
            isDrawingLine = true
            let nl = LineItem(x1: a4.x, y1: a4.y, x2: a4.x, y2: a4.y)
            newLineItem = nl
            dragStartScreen = sp
            return

        case .select:
            break
        }

        // Select mode: check rotation handle, then resize handle, then hit test
        if let item = selectedImage, isOnRotationHandle(screen: sp, item: item) {
            pushUndo()
            isRotatingWithMouse = true
            let f = screenFrame(for: item)
            mouseRotationStartAngle = atan2(sp.y - f.midY, sp.x - f.midX)
            mouseRotationItemStartRotation = item.rotation
            rotationSnappedTo = -1
            dragStartScreen = sp
        } else if let item = selectedText, isOnTextRotationHandle(screen: sp, item: item) {
            pushUndo()
            isRotatingWithMouse = true
            let f = screenFrame(for: item)
            mouseRotationStartAngle = atan2(sp.y - f.midY, sp.x - f.midX)
            mouseRotationItemStartRotation = item.rotation
            rotationSnappedTo = -1
            dragStartScreen = sp
        } else if let item = selectedLine, isOnLineRotationHandle(screen: sp, item: item) {
            pushUndo()
            isRotatingWithMouse = true
            mouseRotLineStart = NSPoint(x: item.x1, y: item.y1)
            mouseRotLineEnd = NSPoint(x: item.x2, y: item.y2)
            gestureLineStart = mouseRotLineStart
            gestureLineEnd = mouseRotLineEnd
            let p1s = toScreen(NSPoint(x: item.x1, y: item.y1))
            let p2s = toScreen(NSPoint(x: item.x2, y: item.y2))
            let midS = NSPoint(x: (p1s.x + p2s.x) / 2, y: (p1s.y + p2s.y) / 2)
            mouseRotationStartAngle = atan2(sp.y - midS.y, sp.x - midS.x)
            lineRotationSnappedTo = -1
            dragStartScreen = sp
        } else if let item = selectedImage, whichHandle(screen: sp, item: item) != 0 {
            pushUndo()
            isResizing = true
            resizeCorner = whichHandle(screen: sp, item: item)
            dragStartScreen = sp
            itemStartWidth = item.width
            itemStartHeight = item.height
            itemStartPos = NSPoint(x: item.x, y: item.y)
        } else if let item = selectedText, whichTextHandle(screen: sp, item: item) != 0 {
            // Text resize handle
            pushUndo()
            isResizingText = true
            resizeCorner = whichTextHandle(screen: sp, item: item)
            dragStartScreen = sp
            itemStartFontSize = item.fontSize
            itemStartPos = NSPoint(x: item.x, y: item.y)
            let sz = item.size
            itemStartWidth = sz.width
            itemStartHeight = sz.height
        } else if let hit = hitText(at: a4) {
            // Text hit — checked BEFORE images so text on images is selectable
            if hit === selectedText && event.clickCount == 2 {
                beginTextEditing(hit)
            } else {
                pushUndo()
                selectText(hit)
                // Bring to front so it stays on top after deselection
                if let idx = texts.firstIndex(where: { $0 === hit }) {
                    texts.remove(at: idx); texts.append(hit)
                }
                isDragging = true
                dragStartScreen = sp
                itemStartPos = NSPoint(x: hit.x, y: hit.y)
            }
        } else if let hit = hitImage(at: a4) {
            if hit === selectedImage && event.clickCount == 2 {
                replaceImage(hit)
            } else {
                pushUndo()
                selectImage(hit)
                // Bring to front so it stays on top after deselection
                if let idx = images.firstIndex(where: { $0 === hit }) {
                    images.remove(at: idx); images.append(hit)
                }
                isDragging = true
                dragStartScreen = sp
                itemStartPos = NSPoint(x: hit.x, y: hit.y)
            }
        } else if let item = selectedLine, hitLineEndpoint(screen: sp, item: item) != 0 {
            // Drag a single endpoint of the selected line
            pushUndo()
            isDraggingLineEndpoint = true
            draggingEndpoint = hitLineEndpoint(screen: sp, item: item)
            dragStartScreen = sp
        } else if let hit = hitLine(at: a4) {
            if hit === selectedLine && event.clickCount == 2 {
                // Double-click: extend line to page edges
                pushUndo()
                let ldx = abs(hit.x2 - hit.x1), ldy = abs(hit.y2 - hit.y1)
                let page = min(max(0, Int(min(hit.y1, hit.y2) / PH)), numPages - 1)
                let pageTop = CGFloat(page) * PH
                if ldx >= ldy {
                    // More horizontal → extend to full page width
                    hit.x1 = 0; hit.x2 = PW
                    let avgY = (hit.y1 + hit.y2) / 2
                    hit.y1 = avgY; hit.y2 = avgY
                } else {
                    // More vertical → extend to full page height
                    hit.y1 = pageTop; hit.y2 = pageTop + PH
                    let avgX = (hit.x1 + hit.x2) / 2
                    hit.x1 = avgX; hit.x2 = avgX
                }
                markDirty(); needsDisplay = true
            } else {
                pushUndo()
                selectLine(hit)
                // Bring to front so it stays on top after deselection
                if let idx = lines.firstIndex(where: { $0 === hit }) {
                    lines.remove(at: idx); lines.append(hit)
                }
                isDragging = true
                dragStartScreen = sp
                itemStartPos = NSPoint(x: hit.x1, y: hit.y1)
                lineStartEnd = NSPoint(x: hit.x2, y: hit.y2)
            }
        } else {
            deselectAll()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { NSCursor.closedHand.set() }
        let sp = convert(event.locationInWindow, from: nil)
        let dx = (sp.x - dragStartScreen.x) / scale
        let dy = (sp.y - dragStartScreen.y) / scale

        if isDrawingLine, let nl = newLineItem {
            var a4 = toA4(sp)
            let rawDx = a4.x - nl.x1, rawDy = a4.y - nl.y1
            let rawLen = hypot(rawDx, rawDy)
            let forceHV = event.modifierFlags.contains(.shift)

            if forceHV {
                // Shift: hard lock to H/V
                let adx = abs(a4.x - nl.x1), ady = abs(a4.y - nl.y1)
                if adx > ady { a4.y = nl.y1 } else { a4.x = nl.x1 }
            } else if rawLen > 20 {
                // Smooth magnetic pull toward H/V
                // The closer the angle is to 0°/90°/180°/270°, the stronger the pull
                let angle = atan2(rawDy, rawDx)  // radians
                let angleDeg = abs(angle) * 180 / .pi
                // Distance from nearest axis in degrees (0° = horizontal, 90° = vertical)
                let distFromH = min(angleDeg, abs(180 - angleDeg))  // 0° or 180°
                let distFromV = abs(90 - angleDeg)                   // 90°

                let magnetZone: CGFloat = 12  // degrees — within this, pull starts
                let lockZone: CGFloat = 3     // degrees — within this, lock fully

                if distFromH < magnetZone {
                    let pull = distFromH < lockZone ? 1.0 : (1.0 - (distFromH - lockZone) / (magnetZone - lockZone))
                    a4.y = nl.y1 + rawDy * (1.0 - pull)
                } else if distFromV < magnetZone {
                    let pull = distFromV < lockZone ? 1.0 : (1.0 - (distFromV - lockZone) / (magnetZone - lockZone))
                    a4.x = nl.x1 + rawDx * (1.0 - pull)
                }
            }
            nl.x2 = a4.x; nl.y2 = a4.y
            // Snap line endpoints to page edges/center and other items
            let page = min(max(0, Int(nl.y1 / PH)), numPages - 1)
            var txEdges: [CGFloat] = [0, PW / 2, PW]
            let pageTop = CGFloat(page) * PH
            var tyEdges: [CGFloat] = [0, PH / 2, PH]
            for img in images {
                let op = min(max(0, Int(img.y / PH)), numPages - 1)
                guard op == page else { continue }
                let oly = img.y - CGFloat(op) * PH
                txEdges.append(contentsOf: [img.x, img.x + img.width / 2, img.x + img.width])
                tyEdges.append(contentsOf: [oly, oly + img.height / 2, oly + img.height])
            }
            let sx2 = snapAxis(dragEdges: [nl.x2], targetEdges: txEdges, threshold: snapThreshold)
            let localY2 = nl.y2 - pageTop
            let sy2 = snapAxis(dragEdges: [localY2], targetEdges: tyEdges, threshold: snapThreshold)
            if sx2.snapped { nl.x2 += sx2.delta }
            if sy2.snapped { nl.y2 += sy2.delta }
            var guides: [SnapGuide] = []
            for pos in sx2.positions { guides.append(SnapGuide(axis: .vertical, a4Pos: pos, page: page)) }
            for pos in sy2.positions { guides.append(SnapGuide(axis: .horizontal, a4Pos: pos, page: page)) }
            activeGuides = guides
            needsDisplay = true
            return
        }

        if isRotatingWithMouse {
            if let item = selectedImage {
                let f = screenFrame(for: item)
                let currentAngle = atan2(sp.y - f.midY, sp.x - f.midX)
                let deltaAngle = -(currentAngle - mouseRotationStartAngle) * 180 / .pi
                item.rotation = applyRotationSnap(rawDegrees: mouseRotationItemStartRotation + deltaAngle)
                markDirty(); needsDisplay = true
            } else if let item = selectedText {
                let f = screenFrame(for: item)
                let currentAngle = atan2(sp.y - f.midY, sp.x - f.midX)
                let deltaAngle = -(currentAngle - mouseRotationStartAngle) * 180 / .pi
                item.rotation = applyRotationSnap(rawDegrees: mouseRotationItemStartRotation + deltaAngle)
                markDirty(); needsDisplay = true
            } else if let item = selectedLine {
                let midX = (mouseRotLineStart.x + mouseRotLineEnd.x) / 2
                let midY = (mouseRotLineStart.y + mouseRotLineEnd.y) / 2
                let midScreen = toScreen(NSPoint(x: midX, y: midY))
                let currentAngle = atan2(sp.y - midScreen.y, sp.x - midScreen.x)
                let deltaAngleRad = currentAngle - mouseRotationStartAngle
                let cosA = cos(deltaAngleRad), sinA = sin(deltaAngleRad)
                let dx1 = mouseRotLineStart.x - midX, dy1 = mouseRotLineStart.y - midY
                let dx2 = mouseRotLineEnd.x - midX, dy2 = mouseRotLineEnd.y - midY
                let newX1 = midX + dx1 * cosA - dy1 * sinA
                let newY1 = midY + dx1 * sinA + dy1 * cosA
                let newX2 = midX + dx2 * cosA - dy2 * sinA
                let newY2 = midY + dx2 * sinA + dy2 * cosA
                var lineAngle = atan2(newY2 - newY1, newX2 - newX1) * 180 / .pi
                if lineAngle < 0 { lineAngle += 360 }
                if let snapDeg = applyLineRotationSnap(lineAngleDeg: lineAngle) {
                    applyLineSnap(line: item, snapDeg: snapDeg, midX: midX, midY: midY)
                } else {
                    item.x1 = newX1; item.y1 = newY1
                    item.x2 = newX2; item.y2 = newY2
                }
                markDirty(); needsDisplay = true
            }
            return
        }

        if isDraggingLineEndpoint, let item = selectedLine {
            let a4 = toA4(sp)
            if draggingEndpoint == 1 { item.x1 = a4.x; item.y1 = a4.y }
            else { item.x2 = a4.x; item.y2 = a4.y }
            // Magnetic H/V pull for endpoint editing too
            let anchorX = draggingEndpoint == 1 ? item.x2 : item.x1
            let anchorY = draggingEndpoint == 1 ? item.y2 : item.y1
            let epX = draggingEndpoint == 1 ? item.x1 : item.x2
            let epY = draggingEndpoint == 1 ? item.y1 : item.y2
            let eDx = epX - anchorX, eDy = epY - anchorY
            let eLen = hypot(eDx, eDy)
            if eLen > 20 && !event.modifierFlags.contains(.shift) {
                let angle = atan2(eDy, eDx)
                let deg = abs(angle) * 180 / .pi
                let distH = min(deg, abs(180 - deg))
                let distV = abs(90 - deg)
                let mag: CGFloat = 12, lock: CGFloat = 3
                if distH < mag {
                    let pull = distH < lock ? 1.0 : (1.0 - (distH - lock) / (mag - lock))
                    let newY = anchorY + eDy * (1.0 - pull)
                    if draggingEndpoint == 1 { item.y1 = newY } else { item.y2 = newY }
                } else if distV < mag {
                    let pull = distV < lock ? 1.0 : (1.0 - (distV - lock) / (mag - lock))
                    let newX = anchorX + eDx * (1.0 - pull)
                    if draggingEndpoint == 1 { item.x1 = newX } else { item.x2 = newX }
                }
            } else if event.modifierFlags.contains(.shift) {
                let adx = abs(eDx), ady = abs(eDy)
                if adx > ady {
                    if draggingEndpoint == 1 { item.y1 = anchorY } else { item.y2 = anchorY }
                } else {
                    if draggingEndpoint == 1 { item.x1 = anchorX } else { item.x2 = anchorX }
                }
            }
            markDirty(); needsDisplay = true
        } else if isResizingText, let item = selectedText {
            let dxSign: CGFloat = (resizeCorner == 1 || resizeCorner == 3) ? -1 : 1
            let newW = max(10, itemStartWidth + dx * dxSign)
            let ratio = newW / itemStartWidth
            item.fontSize = min(200, max(6, itemStartFontSize * ratio))
            let newSz = item.size
            // Anchor opposite corner
            if resizeCorner == 1 || resizeCorner == 3 { // left corners: anchor right
                item.x = itemStartPos.x + itemStartWidth - newSz.width
            } else {
                item.x = itemStartPos.x
            }
            if resizeCorner == 1 || resizeCorner == 2 { // top corners: anchor bottom
                item.y = itemStartPos.y + itemStartHeight - newSz.height
            } else {
                item.y = itemStartPos.y
            }
            let (sdx, sdy, guides) = computeTextSnaps(for: item)
            item.x += sdx; item.y += sdy
            activeGuides = guides
            markDirty()
            needsDisplay = true
        } else if isResizing, let item = selectedImage {
            let freeResize = event.modifierFlags.contains(.option)
            let dxSign: CGFloat = (resizeCorner == 1 || resizeCorner == 3) ? -1 : 1
            let dySign: CGFloat = (resizeCorner == 1 || resizeCorner == 2) ? -1 : 1
            let adjustX = (resizeCorner == 1 || resizeCorner == 3)
            let adjustY = (resizeCorner == 1 || resizeCorner == 2)
            let newW = max(20, itemStartWidth + dx * dxSign)
            let newH: CGFloat
            if freeResize {
                newH = max(20, itemStartHeight + dy * dySign)
            } else {
                newH = newW / item.aspectRatio
            }
            item.width = newW; item.height = newH
            item.x = adjustX ? (itemStartPos.x + itemStartWidth - newW) : itemStartPos.x
            item.y = adjustY ? (itemStartPos.y + itemStartHeight - newH) : itemStartPos.y
            // Snap moving edges
            let resizeSnapT = snapThreshold * 2
            let page = min(max(0, Int(item.y / PH)), numPages - 1)
            let localY = item.y - CGFloat(page) * PH
            var txTargets: [CGFloat] = [0, PW / 2, PW]
            var tyTargets: [CGFloat] = [0, PH / 2, PH]
            for other in images where other !== item {
                let op = min(max(0, Int(other.y / PH)), numPages - 1)
                guard op == page else { continue }
                let oly = other.y - CGFloat(op) * PH
                txTargets.append(contentsOf: [other.x, other.x + other.width / 2, other.x + other.width])
                tyTargets.append(contentsOf: [oly, oly + other.height / 2, oly + other.height])
            }
            var guides: [SnapGuide] = []
            // X snap: snap the moving X edge
            let movingXEdge = adjustX ? item.x : (item.x + item.width)
            var bestXDist: CGFloat = .greatestFiniteMagnitude
            var bestXDelta: CGFloat = 0
            var bestXPos: CGFloat = 0
            for te in txTargets {
                let d = abs(te - movingXEdge)
                if d < bestXDist && d <= resizeSnapT {
                    bestXDist = d; bestXDelta = te - movingXEdge; bestXPos = te
                }
            }
            // Y snap: snap the moving Y edge
            let movingYEdge = adjustY ? localY : (localY + item.height)
            var bestYDist: CGFloat = .greatestFiniteMagnitude
            var bestYDelta: CGFloat = 0
            var bestYPos: CGFloat = 0
            for te in tyTargets {
                let d = abs(te - movingYEdge)
                if d < bestYDist && d <= resizeSnapT {
                    bestYDist = d; bestYDelta = te - movingYEdge; bestYPos = te
                }
            }
            if freeResize {
                if bestXDist <= resizeSnapT {
                    if adjustX { item.x += bestXDelta; item.width -= bestXDelta }
                    else { item.width += bestXDelta }
                    guides.append(SnapGuide(axis: .vertical, a4Pos: bestXPos, page: page))
                }
                if bestYDist <= resizeSnapT {
                    if adjustY { item.y += bestYDelta; item.height -= bestYDelta }
                    else { item.height += bestYDelta }
                    guides.append(SnapGuide(axis: .horizontal, a4Pos: bestYPos, page: page))
                }
            } else {
                if bestXDist <= resizeSnapT && (bestXDist <= bestYDist || bestYDist > resizeSnapT) {
                    if adjustX { item.x += bestXDelta; item.width -= bestXDelta }
                    else { item.width += bestXDelta }
                    item.height = item.width / item.aspectRatio
                    if adjustY { item.y = itemStartPos.y + itemStartHeight - item.height }
                    guides.append(SnapGuide(axis: .vertical, a4Pos: bestXPos, page: page))
                } else if bestYDist <= resizeSnapT {
                    if adjustY { item.y += bestYDelta; item.height -= bestYDelta }
                    else { item.height += bestYDelta }
                    item.width = item.height * item.aspectRatio
                    if adjustX { item.x = itemStartPos.x + itemStartWidth - item.width }
                    guides.append(SnapGuide(axis: .horizontal, a4Pos: bestYPos, page: page))
                }
            }
            activeGuides = guides
            markDirty()
            needsDisplay = true
        } else if isDragging {
            if let item = selectedImage {
                item.x = itemStartPos.x + dx
                item.y = itemStartPos.y + dy
                let (sdx, sdy, guides) = computeSnaps(for: item)
                item.x += sdx; item.y += sdy
                activeGuides = guides
                markDirty()
            } else if let item = selectedText {
                item.x = itemStartPos.x + dx
                item.y = itemStartPos.y + dy
                let (sdx, sdy, guides) = computeTextSnaps(for: item)
                item.x += sdx; item.y += sdy
                activeGuides = guides
                markDirty()
            } else if let item = selectedLine {
                item.x1 = itemStartPos.x + dx
                item.y1 = itemStartPos.y + dy
                item.x2 = lineStartEnd.x + dx
                item.y2 = lineStartEnd.y + dy
                let midX = (item.x1 + item.x2) / 2
                let page = min(max(0, Int(min(item.y1, item.y2) / PH)), numPages - 1)
                let pageTop = CGFloat(page) * PH
                let midLocalY = ((item.y1 + item.y2) / 2) - pageTop
                var txEdges: [CGFloat] = [0, PW / 2, PW]
                var tyEdges: [CGFloat] = [0, PH / 2, PH]
                for img in images {
                    let op = min(max(0, Int(img.y / PH)), numPages - 1)
                    guard op == page else { continue }
                    let oly = img.y - CGFloat(op) * PH
                    txEdges.append(contentsOf: [img.x, img.x + img.width / 2, img.x + img.width])
                    tyEdges.append(contentsOf: [oly, oly + img.height / 2, oly + img.height])
                }
                let sx = snapAxis(dragEdges: [midX], targetEdges: txEdges, threshold: snapThreshold)
                let sy = snapAxis(dragEdges: [midLocalY], targetEdges: tyEdges, threshold: snapThreshold)
                if sx.snapped { item.x1 += sx.delta; item.x2 += sx.delta }
                if sy.snapped { item.y1 += sy.delta; item.y2 += sy.delta }
                var guides: [SnapGuide] = []
                for pos in sx.positions { guides.append(SnapGuide(axis: .vertical, a4Pos: pos, page: page)) }
                for pos in sy.positions { guides.append(SnapGuide(axis: .horizontal, a4Pos: pos, page: page)) }
                activeGuides = guides
                markDirty()
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDrawingLine, let nl = newLineItem {
            let len = hypot(nl.x2 - nl.x1, nl.y2 - nl.y1)
            if len > 2 {
                pushUndo()
                lines.append(nl)
                selectLine(nl)
                markDirty()
            }
            isDrawingLine = false
            newLineItem = nil
            mode = .select
            needsDisplay = true
            return
        }
        isDragging = false
        isResizing = false
        isResizingText = false
        resizeCorner = 0
        isDraggingLineEndpoint = false
        isRotatingWithMouse = false
        activeGuides = []
        NSCursor.arrow.set()
        needsDisplay = true
    }

    // ── Trackpad gestures ──

    @objc func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        if gesture.state == .began {
            if let item = selectedImage {
                pushUndo()
                gestureStartWidth = item.width
                gestureStartHeight = item.height
                isPinchZooming = false
            } else if let item = selectedText {
                pushUndo()
                gestureStartFontSize = item.fontSize
                isPinchZooming = false
            } else if let item = selectedLine {
                pushUndo()
                gestureLineStart = NSPoint(x: item.x1, y: item.y1)
                gestureLineEnd = NSPoint(x: item.x2, y: item.y2)
                isPinchZooming = false
            } else {
                // Nothing selected → zoom canvas
                gestureStartZoom = zoomLevel
                isPinchZooming = true
            }
        }
        if gesture.state == .changed {
            let s = 1 + gesture.magnification
            if isPinchZooming {
                let newZoom = min(4.0, max(0.25, gestureStartZoom * s))
                onZoom?(newZoom)
            } else if let item = selectedImage {
                let cx = item.x + item.width / 2
                let cy = item.y + item.height / 2
                item.width = max(20, gestureStartWidth * s)
                item.height = item.width / item.aspectRatio
                item.x = cx - item.width / 2
                item.y = cy - item.height / 2
                markDirty(); needsDisplay = true
            } else if let item = selectedText {
                item.fontSize = min(200, max(6, gestureStartFontSize * s))
                markDirty(); needsDisplay = true
            } else if let item = selectedLine {
                // Scale line around midpoint
                let mx = (gestureLineStart.x + gestureLineEnd.x) / 2
                let my = (gestureLineStart.y + gestureLineEnd.y) / 2
                item.x1 = mx + (gestureLineStart.x - mx) * s
                item.y1 = my + (gestureLineStart.y - my) * s
                item.x2 = mx + (gestureLineEnd.x - mx) * s
                item.y2 = my + (gestureLineEnd.y - my) * s
                markDirty(); needsDisplay = true
            }
        }
    }

    private var rotationSnappedTo: CGFloat = -1  // currently locked angle, -1 = not snapped
    private lazy var hapticPerformer = NSHapticFeedbackManager.defaultPerformer
    private let rotationSnapThreshold: CGFloat = 3   // degrees to enter snap
    private let rotationEscapeThreshold: CGFloat = 8 // degrees to break free

    /// Apply rotation snap detent logic. Returns the snapped rotation value in degrees.
    private func applyRotationSnap(rawDegrees: CGFloat) -> CGFloat {
        var raw = rawDegrees.truncatingRemainder(dividingBy: 360)
        if raw < 0 { raw += 360 }
        let snapAngles: [CGFloat] = [0, 90, 180, 270, 360]
        if rotationSnappedTo >= 0 {
            let distFromSnap = min(abs(raw - rotationSnappedTo),
                                    abs(raw - rotationSnappedTo + 360),
                                    abs(raw - rotationSnappedTo - 360))
            if distFromSnap < rotationEscapeThreshold {
                return rotationSnappedTo == 360 ? 0 : rotationSnappedTo
            }
            rotationSnappedTo = -1
        }
        for sa in snapAngles {
            let dist = min(abs(raw - sa), abs(raw - sa + 360), abs(raw - sa - 360))
            if dist < rotationSnapThreshold {
                if rotationSnappedTo != sa {
                    hapticPerformer.perform(.alignment, performanceTime: .now)
                    rotationSnappedTo = sa
                }
                return sa == 360 ? 0 : sa
            }
        }
        return raw
    }

    /// Apply line rotation snap. Returns the snapped line angle in degrees, or nil for free rotation.
    private func applyLineRotationSnap(lineAngleDeg: CGFloat) -> CGFloat? {
        let snapAngles: [CGFloat] = [0, 90, 180, 270, 360]
        if lineRotationSnappedTo >= 0 {
            let distFromSnap = min(abs(lineAngleDeg - lineRotationSnappedTo),
                                    abs(lineAngleDeg - lineRotationSnappedTo + 360),
                                    abs(lineAngleDeg - lineRotationSnappedTo - 360))
            if distFromSnap < rotationEscapeThreshold {
                return lineRotationSnappedTo
            }
            lineRotationSnappedTo = -1
        }
        for sa in snapAngles {
            let dist = min(abs(lineAngleDeg - sa), abs(lineAngleDeg - sa + 360), abs(lineAngleDeg - sa - 360))
            if dist < rotationSnapThreshold {
                if lineRotationSnappedTo != sa {
                    hapticPerformer.perform(.alignment, performanceTime: .now)
                    lineRotationSnappedTo = sa
                }
                return sa
            }
        }
        return nil
    }

    @objc func handleRotate(_ gesture: NSRotationGestureRecognizer) {
        if gesture.state == .began { isRotatingWithMouse = false }
        // Rotate images, text, or lines
        if let line = selectedLine {
            handleRotateLine(gesture, line: line)
            return
        }
        // Get current rotation from either image or text
        let currentRotation: CGFloat
        if let img = selectedImage { currentRotation = img.rotation }
        else if let txt = selectedText { currentRotation = txt.rotation }
        else { return }

        if gesture.state == .began {
            pushUndo()
            gestureStartRotation = currentRotation
            rotationSnappedTo = -1
        } else if gesture.state == .changed {
            let degrees = gesture.rotation * 180 / .pi
            var raw = gestureStartRotation + CGFloat(degrees)
            raw = raw.truncatingRemainder(dividingBy: 360)
            if raw < 0 { raw += 360 }

            // Snap logic: sticky detent at 0°, 90°, 180°, 270°
            let snapAngles: [CGFloat] = [0, 90, 180, 270, 360]

            if rotationSnappedTo >= 0 {
                let distFromSnap = min(abs(raw - rotationSnappedTo),
                                        abs(raw - rotationSnappedTo + 360),
                                        abs(raw - rotationSnappedTo - 360))
                if distFromSnap < rotationEscapeThreshold {
                    let snappedVal = rotationSnappedTo == 360 ? 0 : rotationSnappedTo
                    if let img = selectedImage { img.rotation = snappedVal }
                    else if let txt = selectedText { txt.rotation = snappedVal }
                    markDirty(); needsDisplay = true
                    return
                }
                rotationSnappedTo = -1
            }

            for sa in snapAngles {
                let dist = min(abs(raw - sa), abs(raw - sa + 360), abs(raw - sa - 360))
                if dist < rotationSnapThreshold {
                    if rotationSnappedTo != sa {
                        hapticPerformer.perform(.alignment, performanceTime: .now)
                        rotationSnappedTo = sa
                    }
                    let snappedVal = sa == 360 ? 0 : sa
                    if let img = selectedImage { img.rotation = snappedVal }
                    else if let txt = selectedText { txt.rotation = snappedVal }
                    markDirty(); needsDisplay = true
                    return
                }
            }

            if let img = selectedImage { img.rotation = raw }
            else if let txt = selectedText { txt.rotation = raw }
            markDirty(); needsDisplay = true
        }
    }

    private var lineRotationSnappedTo: CGFloat = -1  // snapped line angle in degrees, -1 = free
    private var lineGestureAngleRad: CGFloat = 0     // raw gesture rotation in radians

    private func handleRotateLine(_ gesture: NSRotationGestureRecognizer, line: LineItem) {
        if gesture.state == .began {
            pushUndo()
            gestureLineStart = NSPoint(x: line.x1, y: line.y1)
            gestureLineEnd = NSPoint(x: line.x2, y: line.y2)
            lineRotationSnappedTo = -1
            lineGestureAngleRad = 0
        } else if gesture.state == .changed {
            let rawAngle = -CGFloat(gesture.rotation)  // radians
            let midX = (gestureLineStart.x + gestureLineEnd.x) / 2
            let midY = (gestureLineStart.y + gestureLineEnd.y) / 2

            // Compute what the resulting line angle would be
            let cosA = cos(rawAngle), sinA = sin(rawAngle)
            let dx2 = gestureLineEnd.x - midX, dy2 = gestureLineEnd.y - midY
            let newDx = dx2 * cosA - dy2 * sinA
            let newDy = dx2 * sinA + dy2 * cosA
            var lineAngle = atan2(newDy, newDx) * 180 / .pi
            if lineAngle < 0 { lineAngle += 360 }

            // Snap at H/V (0°, 90°, 180°, 270°)
            let snapAngles: [CGFloat] = [0, 90, 180, 270, 360]

            if lineRotationSnappedTo >= 0 {
                // Currently snapped — hold until escape
                let distFromSnap = min(abs(lineAngle - lineRotationSnappedTo),
                                        abs(lineAngle - lineRotationSnappedTo + 360),
                                        abs(lineAngle - lineRotationSnappedTo - 360))
                if distFromSnap < rotationEscapeThreshold {
                    // Stay locked — compute the angle that makes the line exactly at snap
                    applyLineSnap(line: line, snapDeg: lineRotationSnappedTo,
                                  midX: midX, midY: midY)
                    markDirty(); needsDisplay = true
                    return
                }
                lineRotationSnappedTo = -1
            }

            // Check if we should snap
            for sa in snapAngles {
                let dist = min(abs(lineAngle - sa), abs(lineAngle - sa + 360), abs(lineAngle - sa - 360))
                if dist < rotationSnapThreshold {
                    if lineRotationSnappedTo != sa {
                        hapticPerformer.perform(.alignment, performanceTime: .now)
                        lineRotationSnappedTo = sa
                    }
                    applyLineSnap(line: line, snapDeg: sa, midX: midX, midY: midY)
                    markDirty(); needsDisplay = true
                    return
                }
            }

            // Free rotation
            let dx1 = gestureLineStart.x - midX, dy1 = gestureLineStart.y - midY
            line.x1 = midX + dx1 * cosA - dy1 * sinA
            line.y1 = midY + dx1 * sinA + dy1 * cosA
            line.x2 = midX + newDx
            line.y2 = midY + newDy
            markDirty(); needsDisplay = true
        }
    }

    /// Snap a line to an exact angle (degrees) around its midpoint, preserving length.
    private func applyLineSnap(line: LineItem, snapDeg: CGFloat, midX: CGFloat, midY: CGFloat) {
        let halfLen = hypot(gestureLineEnd.x - gestureLineStart.x,
                            gestureLineEnd.y - gestureLineStart.y) / 2
        let rad = (snapDeg == 360 ? 0 : snapDeg) * .pi / 180
        let hx = halfLen * cos(rad), hy = halfLen * sin(rad)
        line.x1 = midX - hx; line.y1 = midY - hy
        line.x2 = midX + hx; line.y2 = midY + hy
    }

    // ── Keyboard ──

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)
        let nudge: CGFloat = shift ? 10 : 1

        switch event.keyCode {
        case 123: // Left
            nudgeSelected(dx: -nudge, dy: 0)
        case 124: // Right
            nudgeSelected(dx: nudge, dy: 0)
        case 125: // Down
            nudgeSelected(dx: 0, dy: nudge)
        case 126: // Up
            nudgeSelected(dx: 0, dy: -nudge)
        case 51: // Delete
            if !cmd { deleteSelected() }
        default:
            super.keyDown(with: event)
        }
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        if let item = selectedImage {
            pushUndo(); item.x += dx; item.y += dy; markDirty(); needsDisplay = true
        } else if let item = selectedText {
            pushUndo(); item.x += dx; item.y += dy; markDirty(); needsDisplay = true
        } else if let item = selectedLine {
            pushUndo()
            item.x1 += dx; item.y1 += dy; item.x2 += dx; item.y2 += dy
            markDirty(); needsDisplay = true
        }
    }

    // ── Text editing ──

    func beginTextEditing(_ item: TextItem) {
        commitTextEditing()
        editingTextItem = item
        let o = toScreen(NSPoint(x: item.x, y: item.y))
        let sz = item.size
        let field = NSTextField(frame: NSRect(x: o.x, y: o.y,
                                              width: max(100, sz.width * scale + 20),
                                              height: max(24, sz.height * scale + 4)))
        field.stringValue = item.text
        field.font = NSFont(name: item.fontName, size: item.fontSize * scale)
            ?? NSFont.systemFont(ofSize: item.fontSize * scale)
        field.textColor = item.color
        field.isBordered = true
        field.isEditable = true
        field.backgroundColor = .white
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldAction(_:))
        addSubview(field)
        field.selectText(nil)
        editingTextField = field
    }

    @objc func textFieldAction(_ sender: NSTextField) {
        commitTextEditing()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = editingTextField, let item = editingTextItem else { return }
        let font = NSFont(name: item.fontName, size: item.fontSize * scale)
            ?? NSFont.systemFont(ofSize: item.fontSize * scale)
        let textSize = (field.stringValue as NSString).size(withAttributes: [.font: font])
        field.frame.size.width = max(100, textSize.width + 20)
        field.frame.size.height = max(24, textSize.height + 4)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }

    func commitTextEditing() {
        guard let field = editingTextField, let item = editingTextItem else { return }
        let newText = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newText.isEmpty {
            pushUndo()
            texts.removeAll { $0 === item }
            deselectAll()
        } else if newText != item.text {
            pushUndo()
            item.text = newText
        }
        field.removeFromSuperview()
        editingTextField = nil
        editingTextItem = nil
        markDirty()
        needsDisplay = true
    }

    // ── Drag & drop from Finder ──

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingContentsConformToTypes: NSImage.imageTypes]) as? [URL] else {
            // Try pasteboard image directly
            if let img = NSImage(pasteboard: sender.draggingPasteboard) {
                let sp = convert(sender.draggingLocation, from: nil)
                let a4 = toA4(sp)
                pushUndo()
                var w = img.size.width
                if w > PW * 0.6 { w = PW * 0.6 }
                let item = ImageItem(image: img, x: a4.x - w / 2, y: a4.y, width: w)
                images.append(item)
                selectImage(item)
                markDirty()
                return true
            }
            return false
        }
        let sp = convert(sender.draggingLocation, from: nil)
        let a4 = toA4(sp)
        pushUndo()
        var offset: CGFloat = 0
        for url in items {
            guard let img = NSImage(contentsOf: url) else { continue }
            var w = img.size.width
            if w > PW * 0.6 { w = PW * 0.6 }
            let item = ImageItem(image: img, x: a4.x - w / 2 + offset, y: a4.y + offset, width: w)
            images.append(item)
            selectImage(item)
            offset += 15
        }
        markDirty()
        return true
    }

    // ── Actions ──

    func visiblePage() -> Int {
        guard let sv = enclosingScrollView else { return 0 }
        let mid = sv.contentView.bounds.midY
        var best = 0, bestD: CGFloat = .greatestFiniteMagnitude
        for i in 0..<numPages {
            let d = abs(pageRect(for: i).midY - mid)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func pasteImage() {
        guard let image = NSImage(pasteboard: .general) else { return }
        pushUndo()
        var w = image.size.width
        if w > PW * 0.6 { w = PW * 0.6 }
        let pg = visiblePage()
        let off = CGFloat(pasteCount % 5) * 18
        let item = ImageItem(image: image,
                             x: (PW - w) / 2 + off,
                             y: CGFloat(pg) * PH + 80 + off,
                             width: w)
        images.append(item)
        pasteCount += 1
        selectImage(item)
        markDirty()
    }

    func addPage() {
        numPages += 1
        markDirty()
    }

    func removePage() {
        guard numPages > 1 else { return }
        pushUndo()
        let top = CGFloat(numPages - 1) * PH
        images.removeAll { $0.y >= top }
        texts.removeAll { $0.y >= top }
        lines.removeAll { min($0.y1, $0.y2) >= top }
        deselectAll()
        numPages -= 1
        markDirty()
    }

    func replaceImage(_ item: ImageItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let newImg = NSImage(contentsOf: url) else { return }
        pushUndo()
        item.image = newImg
        item.aspectRatio = newImg.size.width / newImg.size.height
        markDirty(); needsDisplay = true
    }

    func deleteSelected() {
        if let item = selectedImage {
            pushUndo()
            images.removeAll { $0 === item }
            deselectAll()
            markDirty()
        } else if let item = selectedText {
            pushUndo()
            texts.removeAll { $0 === item }
            deselectAll()
            markDirty()
        } else if let item = selectedLine {
            pushUndo()
            lines.removeAll { $0 === item }
            deselectAll()
            markDirty()
        }
        needsDisplay = true
    }

    func duplicateSelected() {
        if let item = selectedImage {
            pushUndo()
            let dup = item.clone()
            images.append(dup)
            selectImage(dup)
            markDirty()
        } else if let item = selectedText {
            pushUndo()
            let dup = item.clone()
            texts.append(dup)
            selectText(dup)
            markDirty()
        } else if let item = selectedLine {
            pushUndo()
            let dup = item.clone()
            lines.append(dup)
            selectLine(dup)
            markDirty()
        }
    }

    func bringToFront() {
        if let item = selectedImage, let idx = images.firstIndex(where: { $0 === item }) {
            pushUndo(); images.remove(at: idx); images.append(item); markDirty(); needsDisplay = true
        } else if let item = selectedText, let idx = texts.firstIndex(where: { $0 === item }) {
            pushUndo(); texts.remove(at: idx); texts.append(item); markDirty(); needsDisplay = true
        } else if let item = selectedLine, let idx = lines.firstIndex(where: { $0 === item }) {
            pushUndo(); lines.remove(at: idx); lines.append(item); markDirty(); needsDisplay = true
        }
    }

    func sendToBack() {
        if let item = selectedImage, let idx = images.firstIndex(where: { $0 === item }) {
            pushUndo(); images.remove(at: idx); images.insert(item, at: 0); markDirty(); needsDisplay = true
        } else if let item = selectedText, let idx = texts.firstIndex(where: { $0 === item }) {
            pushUndo(); texts.remove(at: idx); texts.insert(item, at: 0); markDirty(); needsDisplay = true
        } else if let item = selectedLine, let idx = lines.firstIndex(where: { $0 === item }) {
            pushUndo(); lines.remove(at: idx); lines.insert(item, at: 0); markDirty(); needsDisplay = true
        }
    }

    func rotateSelected(degrees: CGFloat = 90) {
        if let item = selectedImage {
            pushUndo()
            item.rotate(by: degrees)
            markDirty(); needsDisplay = true
        } else if let item = selectedText {
            pushUndo()
            item.rotation = (item.rotation + degrees).truncatingRemainder(dividingBy: 360)
            if item.rotation < 0 { item.rotation += 360 }
            markDirty(); needsDisplay = true
        } else if let item = selectedLine {
            // Rotate line around its midpoint
            pushUndo()
            let rad = degrees * .pi / 180
            let mx = (item.x1 + item.x2) / 2, my = (item.y1 + item.y2) / 2
            let cosA = cos(rad), sinA = sin(rad)
            let dx1 = item.x1 - mx, dy1 = item.y1 - my
            item.x1 = mx + dx1 * cosA - dy1 * sinA
            item.y1 = my + dx1 * sinA + dy1 * cosA
            let dx2 = item.x2 - mx, dy2 = item.y2 - my
            item.x2 = mx + dx2 * cosA - dy2 * sinA
            item.y2 = my + dx2 * sinA + dy2 * cosA
            markDirty(); needsDisplay = true
        }
    }

    func setSelectedOpacity(_ val: CGFloat) {
        guard let item = selectedImage else { return }
        pushUndo()
        item.opacity = val
        markDirty()
        needsDisplay = true
    }

    func setSelectedFrameColor(_ color: NSColor?) {
        if let item = selectedImage {
            pushUndo()
            item.frameColor = color
            markDirty(); needsDisplay = true
        } else if let item = selectedLine, let c = color {
            pushUndo()
            item.color = c
            markDirty(); needsDisplay = true
        }
    }

    func setSelectedFrameWidth(_ w: CGFloat) {
        if let item = selectedImage {
            pushUndo()
            item.frameWidth = w
            markDirty(); needsDisplay = true
        } else if let item = selectedLine {
            pushUndo()
            item.lineWidth = w
            markDirty(); needsDisplay = true
        }
    }

    func toggleFrame() {
        guard let item = selectedImage else { return }
        pushUndo()
        if item.frameColor != nil {
            item.frameColor = nil
        } else {
            item.frameColor = .black
            item.frameWidth = 1
        }
        markDirty()
        needsDisplay = true
    }

    func changePageSize(_ newSize: PageSize) {
        guard newSize != pageSize else { return }
        pushUndo()
        pageSize = newSize
        markDirty()
        onRelayout?()
        needsDisplay = true
    }

    func toggleOrientation() {
        pushUndo()
        isLandscape.toggle()
        markDirty()
        onRelayout?()
        needsDisplay = true
    }

    func changeBgColor(_ color: NSColor) {
        guard color != bgColor else { return }
        pushUndo()
        bgColor = color
        markDirty()
        needsDisplay = true
    }

    func toggleGrid() {
        showGrid.toggle()
        needsDisplay = true
    }

    // ── PDF Export ──

    func exportPDF() {
        deselectAll()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "layout.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: PW, height: PH)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }

        for pg in 0..<numPages {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: PH)
            ctx.scaleBy(x: 1, y: -1)

            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            NSBezierPath(rect: NSRect(x: 0, y: 0, width: PW, height: PH)).setClip()
            bgColor.setFill()
            NSRect(x: 0, y: 0, width: PW, height: PH).fill()

            let top = CGFloat(pg) * PH

            // Lines
            for item in lines {
                let minY = min(item.y1, item.y2), maxY = max(item.y1, item.y2)
                guard maxY > top && minY < top + PH else { continue }
                item.color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = item.lineWidth
                path.move(to: NSPoint(x: item.x1, y: item.y1 - top))
                path.line(to: NSPoint(x: item.x2, y: item.y2 - top))
                path.stroke()
            }

            // Images
            for item in images {
                guard item.y + item.height > top && item.y < top + PH else { continue }
                let rect = NSRect(x: item.x, y: item.y - top,
                                  width: item.width, height: item.height)

                let hasRotation = abs(item.rotation) > 0.01
                if hasRotation {
                    NSGraphicsContext.saveGraphicsState()
                    let rot = NSAffineTransform()
                    rot.translateX(by: rect.midX, yBy: rect.midY)
                    rot.rotate(byDegrees: -item.rotation)
                    rot.translateX(by: -rect.midX, yBy: -rect.midY)
                    rot.concat()
                }

                item.image.draw(in: rect, from: NSRect(origin: .zero, size: item.image.size),
                                operation: .sourceOver, fraction: item.opacity,
                                respectFlipped: true, hints: nil)

                if let fc = item.frameColor {
                    fc.setStroke()
                    let bezel = NSBezierPath(rect: rect)
                    bezel.lineWidth = item.frameWidth
                    bezel.stroke()
                }

                if hasRotation {
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            // Texts
            for item in texts {
                let sz = item.size
                guard item.y + sz.height > top && item.y < top + PH else { continue }
                let textPt = NSPoint(x: item.x, y: item.y - top)
                let hasTextRotation = abs(item.rotation) > 0.01
                if hasTextRotation {
                    NSGraphicsContext.saveGraphicsState()
                    let tcx = textPt.x + sz.width / 2, tcy = textPt.y + sz.height / 2
                    let rot = NSAffineTransform()
                    rot.translateX(by: tcx, yBy: tcy)
                    rot.rotate(byDegrees: -item.rotation)
                    rot.translateX(by: -tcx, yBy: -tcy)
                    rot.concat()
                }
                (item.text as NSString).draw(at: textPt, withAttributes: item.attrs)
                if hasTextRotation {
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }

        ctx.closePDF()
        try? pdfData.write(to: url)
        clearDirty()
    }

    func loadPDF(from url: URL) {
        guard let pdfDoc = PDFDocument(url: url) else { NSSound.beep(); return }
        let pageCount = pdfDoc.pageCount
        guard pageCount > 0 else { return }

        pushUndo()
        deselectAll()
        images.removeAll()
        texts.removeAll()
        lines.removeAll()

        // Detect page size and orientation from first page
        if let firstPage = pdfDoc.page(at: 0) {
            let box = firstPage.bounds(for: .mediaBox)
            let rot = firstPage.rotation
            let isRotated = (rot == 90 || rot == 270)
            let effW = isRotated ? box.height : box.width
            let effH = isRotated ? box.width : box.height

            let shortSide = min(effW, effH)
            let longSide = max(effW, effH)
            let a4Diff = abs(shortSide - 595) + abs(longSide - 842)
            let letterDiff = abs(shortSide - 612) + abs(longSide - 792)
            pageSize = letterDiff < a4Diff ? .letter : .a4
            isLandscape = effW > effH
        }

        numPages = pageCount

        let renderScale: CGFloat = 2.0
        for i in 0..<pageCount {
            guard let pdfPage = pdfDoc.page(at: i) else { continue }
            let mediaBox = pdfPage.bounds(for: .mediaBox)

            let renderW = mediaBox.width * renderScale
            let renderH = mediaBox.height * renderScale
            let image = NSImage(size: NSSize(width: renderW, height: renderH))
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                NSColor.white.setFill()
                NSRect(origin: .zero, size: NSSize(width: renderW, height: renderH)).fill()
                ctx.scaleBy(x: renderScale, y: renderScale)
                pdfPage.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()

            let item = ImageItem(image: image, x: 0, y: CGFloat(i) * PH, width: PW)
            item.height = PH
            item.aspectRatio = PW / PH
            images.append(item)
        }

        markDirty()
        onRelayout?()
        needsDisplay = true
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - App Delegate
// ─────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var scrollView: NSScrollView!
    var doc: DocumentView!

    // Toolbar controls
    var pageSizePopup: NSPopUpButton!
    var bgPopup: NSPopUpButton!
    var framePopup: NSPopUpButton!
    var frameWidthPopup: NSPopUpButton!
    var opacitySlider: NSSlider!
    var opacityLabel: NSTextField!
    var gridBtn: NSButton!
    var textModeBtn: NSButton!
    var lineModeBtn: NSButton!
    var textColorPopup: NSPopUpButton!
    var fontSizePopup: NSPopUpButton!
    var boldBtn: NSButton!
    var italicBtn: NSButton!

    var defaultTextColor: NSColor = .black
    var defaultFontSize: CGFloat = 16

    func applicationDidFinishLaunching(_ notification: Notification) {
        doc = DocumentView(frame: .zero)
        doc.onRelayout = { [weak self] in self?.relayout() }
        doc.onDirtyChanged = { [weak self] in
            self?.window.isDocumentEdited = self?.doc.isDirty ?? false
        }
        doc.onSelectionChanged = { [weak self] in self?.updateToolbarForSelection() }
        doc.onZoom = { [weak self] z in self?.applyZoom(z) }

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = doc
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.91, alpha: 1)

        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(relayout),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)

        // Build toolbar + scrollview container
        let toolbar = buildToolbar()
        let sep = NSBox(frame: .zero)
        sep.boxType = .separator

        let stack = NSStackView(views: [toolbar, sep, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        sep.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Constraints
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            toolbar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 880),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "PDF Layout"
        window.contentView = stack
        window.minSize = NSSize(width: 420, height: 400)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        setupMenus()
        relayout()
        centerCanvasInViewport()
        updateToolbarForSelection()
    }

    private func centerCanvasInViewport() {
        let clipW = scrollView.contentView.bounds.width
        let clipH = scrollView.contentView.bounds.height
        let contentCenterX = doc.canvasOriginX + (doc.pageW + doc.pad * 2) / 2
        let contentCenterY = doc.canvasOriginY + doc.pad + doc.pageH / 2
        let ox = contentCenterX - clipW / 2
        let oy = contentCenterY - clipH / 2
        scrollView.contentView.scroll(to: NSPoint(x: max(0, ox), y: max(0, oy)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // ── Toolbar ──

    func buildToolbar() -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 32))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        // ── Page size & background ──
        pageSizePopup = makePopup(["A4", "Letter"], action: #selector(pageSizeChanged(_:)))
        stack.addArrangedSubview(pageSizePopup)

        let orientBtn = makeIconBtn("rectangle.landscape.rotate",
                                     tip: "Toggle landscape/portrait (⌘L)",
                                     action: #selector(toggleOrientation))
        stack.addArrangedSubview(orientBtn)

        bgPopup = makePopup(["White", "Gray", "Cream", "Black"],
                             action: #selector(bgColorChanged(_:)))
        bgPopup.toolTip = "Page background color"
        stack.addArrangedSubview(bgPopup)

        stack.addArrangedSubview(makeDivider())

        // ── Insert tools ──
        let pasteBtn = makeIconBtn("doc.on.clipboard", tip: "Paste image (⌘V)",
                                    action: #selector(pasteImage))
        stack.addArrangedSubview(pasteBtn)

        textModeBtn = makeIconBtn("textformat", tip: "Add text — click on page",
                                   action: #selector(enterTextMode))
        textModeBtn.setButtonType(.pushOnPushOff)
        stack.addArrangedSubview(textModeBtn)

        lineModeBtn = makeIconBtn("line.diagonal", tip: "Draw line — click and drag",
                                   action: #selector(enterLineMode))
        lineModeBtn.setButtonType(.pushOnPushOff)
        stack.addArrangedSubview(lineModeBtn)

        stack.addArrangedSubview(makeDivider())

        // ── Frame & Rotate ──
        framePopup = makePopup(["No Frame", "Black", "Gray", "Red", "Blue"],
                                action: #selector(frameChanged(_:)))
        framePopup.toolTip = "Frame color"
        stack.addArrangedSubview(framePopup)

        frameWidthPopup = makePopup(["0.5pt", "1pt", "2pt"],
                                     action: #selector(frameWidthChanged(_:)))
        frameWidthPopup.selectItem(at: 1)
        frameWidthPopup.toolTip = "Frame thickness"
        stack.addArrangedSubview(frameWidthPopup)

        let rotateBtn = makeIconBtn("rotate.right", tip: "Rotate 90° (⌘R)",
                                     action: #selector(rotateImage))
        stack.addArrangedSubview(rotateBtn)

        // ── Opacity ──
        opacitySlider = NSSlider(value: 1.0, minValue: 0.05, maxValue: 1.0,
                                  target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.controlSize = .mini
        opacitySlider.toolTip = "Image opacity"
        opacitySlider.widthAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(opacitySlider)
        opacityLabel = NSTextField(labelWithString: "100%")
        opacityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor
        opacityLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(opacityLabel)

        stack.addArrangedSubview(makeDivider())

        // ── Text controls ──
        textColorPopup = makePopup(["Black", "Red", "Blue", "Gray", "White"],
                                    action: #selector(textColorChanged(_:)))
        textColorPopup.toolTip = "Text color"
        stack.addArrangedSubview(textColorPopup)

        fontSizePopup = makePopup(["10", "12", "14", "16", "20", "24", "32", "48", "72"],
                                   action: #selector(fontSizeChanged(_:)))
        fontSizePopup.selectItem(at: 3)  // default 16
        fontSizePopup.toolTip = "Font size"
        stack.addArrangedSubview(fontSizePopup)

        boldBtn = makeIconBtn("bold", tip: "Bold", action: #selector(toggleBold))
        boldBtn.setButtonType(.pushOnPushOff)
        stack.addArrangedSubview(boldBtn)

        italicBtn = makeIconBtn("italic", tip: "Italic", action: #selector(toggleItalic))
        italicBtn.setButtonType(.pushOnPushOff)
        stack.addArrangedSubview(italicBtn)

        stack.addArrangedSubview(makeDivider())

        // ── Grid ──
        gridBtn = makeIconBtn("grid", tip: "Toggle grid (⌘G)", action: #selector(toggleGrid))
        gridBtn.setButtonType(.toggle)
        stack.addArrangedSubview(gridBtn)

        // ── Pages ──
        let addPgBtn = makeIconBtn("plus.rectangle", tip: "Add page (⌘N)",
                                    action: #selector(addPage))
        let rmPgBtn = makeIconBtn("minus.rectangle", tip: "Remove last page (⌘⇧N)",
                                   action: #selector(removePage))
        stack.addArrangedSubview(addPgBtn)
        stack.addArrangedSubview(rmPgBtn)

        // ── Save ──
        let saveBtn = makeIconBtn("square.and.arrow.down", tip: "Save as PDF (⌘S)",
                                   action: #selector(savePDF))
        stack.addArrangedSubview(saveBtn)

        // ── Right spacer ──
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(spacer)

        return bar
    }

    func makeIconBtn(_ symbolName: String, tip: String, action: Selector) -> NSButton {
        let btn: NSButton
        if let img = NSImage(systemSymbolName: symbolName,
                              accessibilityDescription: tip) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            let styled = img.withSymbolConfiguration(config) ?? img
            btn = NSButton(image: styled, target: self, action: action)
            btn.imagePosition = .imageOnly
        } else {
            btn = NSButton(title: String(tip.prefix(4)), target: self, action: action)
        }
        btn.controlSize = .mini
        btn.bezelStyle = .rounded
        btn.isBordered = true
        btn.toolTip = tip
        btn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        return btn
    }

    func makePopup(_ items: [String], action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .mini
        popup.font = NSFont.systemFont(ofSize: 10)
        for title in items { popup.addItem(withTitle: title) }
        popup.target = self; popup.action = action
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        return popup
    }

    func makeDivider() -> NSView {
        let div = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 16))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.separatorColor.cgColor
        div.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            div.widthAnchor.constraint(equalToConstant: 1),
            div.heightAnchor.constraint(equalToConstant: 16),
        ])
        div.setContentHuggingPriority(.required, for: .horizontal)
        div.setContentCompressionResistancePriority(.required, for: .horizontal)
        return div
    }

    func updateToolbarForSelection() {
        let hasImg = doc.selectedImage != nil
        let hasLine = doc.selectedLine != nil
        let hasTxt = doc.selectedText != nil
        framePopup.isEnabled = hasImg || hasLine
        frameWidthPopup.isEnabled = hasImg || hasLine
        opacitySlider.isEnabled = hasImg
        textColorPopup.isEnabled = hasTxt
        fontSizePopup.isEnabled = hasTxt
        boldBtn.isEnabled = hasTxt
        italicBtn.isEnabled = hasTxt

        // Highlight active mode
        textModeBtn.state = doc.mode == .addText ? .on : .off
        lineModeBtn.state = doc.mode == .drawLine ? .on : .off

        if let item = doc.selectedImage {
            opacitySlider.doubleValue = Double(item.opacity)
            opacityLabel.stringValue = "\(Int(item.opacity * 100))%"
            if let fc = item.frameColor {
                if fc == .black { framePopup.selectItem(at: 1) }
                else if fc == NSColor.darkGray { framePopup.selectItem(at: 2) }
                else if fc == .red { framePopup.selectItem(at: 3) }
                else if fc == .blue { framePopup.selectItem(at: 4) }
                else { framePopup.selectItem(at: 1) }
            } else {
                framePopup.selectItem(at: 0)
            }
            if item.frameWidth <= 0.5 { frameWidthPopup.selectItem(at: 0) }
            else if item.frameWidth <= 1 { frameWidthPopup.selectItem(at: 1) }
            else { frameWidthPopup.selectItem(at: 2) }
        } else if let item = doc.selectedLine {
            let c = item.color
            if c == .black { framePopup.selectItem(at: 1) }
            else if c == NSColor.darkGray { framePopup.selectItem(at: 2) }
            else if c == .red { framePopup.selectItem(at: 3) }
            else if c == .blue { framePopup.selectItem(at: 4) }
            else { framePopup.selectItem(at: 1) }
            if item.lineWidth <= 0.5 { frameWidthPopup.selectItem(at: 0) }
            else if item.lineWidth <= 1 { frameWidthPopup.selectItem(at: 1) }
            else { frameWidthPopup.selectItem(at: 2) }
            opacitySlider.doubleValue = 1.0
            opacityLabel.stringValue = "100%"
        } else {
            opacitySlider.doubleValue = 1.0
            opacityLabel.stringValue = "100%"
        }

        if let item = doc.selectedText {
            let tc = item.color
            if tc == .black { textColorPopup.selectItem(at: 0) }
            else if tc == .red { textColorPopup.selectItem(at: 1) }
            else if tc == .blue { textColorPopup.selectItem(at: 2) }
            else if tc == NSColor.darkGray { textColorPopup.selectItem(at: 3) }
            else if tc == .white { textColorPopup.selectItem(at: 4) }
            let sizes: [CGFloat] = [10, 12, 14, 16, 20, 24, 32, 48, 72]
            if let idx = sizes.firstIndex(where: { abs($0 - item.fontSize) < 0.5 }) {
                fontSizePopup.selectItem(at: idx)
            }
            boldBtn.state = item.isBold ? .on : .off
            italicBtn.state = item.isItalic ? .on : .off
        } else {
            boldBtn.state = .off
            italicBtn.state = .off
        }
    }

    // ── Toolbar Actions ──

    @objc func pageSizeChanged(_ sender: NSPopUpButton) {
        let ps = PageSize.allCases[sender.indexOfSelectedItem]
        doc.changePageSize(ps)
    }

    @objc func bgColorChanged(_ sender: NSPopUpButton) {
        let colors: [NSColor] = [.white, NSColor(white: 0.93, alpha: 1),
                                  NSColor(red: 1, green: 0.98, blue: 0.94, alpha: 1), .black]
        doc.changeBgColor(colors[sender.indexOfSelectedItem])
    }

    @objc func frameChanged(_ sender: NSPopUpButton) {
        let colors: [NSColor?] = [nil, .black, .darkGray, .red, .blue]
        doc.setSelectedFrameColor(colors[sender.indexOfSelectedItem])
    }

    @objc func frameWidthChanged(_ sender: NSPopUpButton) {
        let widths: [CGFloat] = [0.5, 1, 2]
        doc.setSelectedFrameWidth(widths[sender.indexOfSelectedItem])
    }

    @objc func rotateImage() { doc.rotateSelected() }

    @objc func opacityChanged(_ sender: NSSlider) {
        let val = CGFloat(sender.doubleValue)
        opacityLabel.stringValue = "\(Int(val * 100))%"
        doc.setSelectedOpacity(val)
    }

    @objc func toggleGrid() {
        doc.toggleGrid()
        gridBtn.state = doc.showGrid ? .on : .off
        updateToolbarForSelection()
    }

    @objc func enterTextMode() {
        doc.mode = doc.mode == .addText ? .select : .addText
        updateToolbarForSelection()
    }

    @objc func enterLineMode() {
        doc.mode = doc.mode == .drawLine ? .select : .drawLine
        updateToolbarForSelection()
    }

    @objc func textColorChanged(_ sender: NSPopUpButton) {
        let colors: [NSColor] = [.black, .red, .blue, .darkGray, .white]
        let color = colors[sender.indexOfSelectedItem]
        defaultTextColor = color
        doc.defaultTextColor = color
        if let item = doc.selectedText {
            doc.pushUndo(); item.color = color; doc.markDirty(); doc.needsDisplay = true
        }
    }

    @objc func fontSizeChanged(_ sender: NSPopUpButton) {
        let sizes: [CGFloat] = [10, 12, 14, 16, 20, 24, 32, 48, 72]
        let sz = sizes[sender.indexOfSelectedItem]
        defaultFontSize = sz
        doc.defaultFontSize = sz
        if let item = doc.selectedText {
            doc.pushUndo(); item.fontSize = sz; doc.markDirty(); doc.needsDisplay = true
        }
    }

    @objc func toggleBold() {
        if let item = doc.selectedText {
            doc.pushUndo(); item.isBold.toggle(); doc.markDirty(); doc.needsDisplay = true
            boldBtn.state = item.isBold ? .on : .off
        }
    }

    @objc func toggleItalic() {
        if let item = doc.selectedText {
            doc.pushUndo(); item.isItalic.toggle(); doc.markDirty(); doc.needsDisplay = true
            italicBtn.state = item.isItalic ? .on : .off
        }
    }

    // ── Layout ──

    @objc func relayout() {
        let clipW = scrollView.contentView.bounds.width
        let clipH = scrollView.contentView.bounds.height

        doc.viewportW = clipW * doc.zoomLevel

        let contentW = doc.pageW + doc.pad * 2
        let contentH = doc.totalHeight(forWidth: contentW)

        // Add generous margins for free panning (Figma-like)
        let marginH = clipW
        let marginV = clipH
        let docW = max(contentW + marginH * 2, clipW)
        let docH = max(contentH + marginV * 2, clipH)

        // Center content within document
        doc.canvasOriginX = (docW - contentW) / 2
        doc.canvasOriginY = (docH - contentH) / 2

        doc.setFrameSize(NSSize(width: docW, height: docH))
        doc.needsDisplay = true
    }

    // ── Menu ──

    func setupMenus() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About PDF Layout", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit PDF Layout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open PDF\u{2026}", action: #selector(openPDF), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(NSMenuItem.separator())
        let save = NSMenuItem(title: "Save as PDF\u{2026}", action: #selector(savePDF), keyEquivalent: "s")
        save.target = self
        fileMenu.addItem(save)
        fileMenu.addItem(NSMenuItem.separator())
        let newPg = NSMenuItem(title: "New Page", action: #selector(addPage), keyEquivalent: "n")
        newPg.target = self; fileMenu.addItem(newPg)
        let rmPg = NSMenuItem(title: "Remove Last Page", action: #selector(removePage), keyEquivalent: "n")
        rmPg.target = self; rmPg.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(rmPg)
        fileMenu.addItem(NSMenuItem.separator())
        let orient = NSMenuItem(title: "Toggle Landscape", action: #selector(toggleOrientation), keyEquivalent: "l")
        orient.target = self; fileMenu.addItem(orient)
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(doUndo), keyEquivalent: "z")
        undoItem.target = self; editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: #selector(doRedo), keyEquivalent: "z")
        redoItem.target = self; redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        let paste = NSMenuItem(title: "Paste", action: #selector(pasteImage), keyEquivalent: "v")
        paste.target = self; editMenu.addItem(paste)
        let dup = NSMenuItem(title: "Duplicate", action: #selector(duplicateSelected), keyEquivalent: "d")
        dup.target = self; editMenu.addItem(dup)
        let del = NSMenuItem(title: "Delete", action: #selector(deleteSelected), keyEquivalent: "\u{8}")
        del.target = self; del.keyEquivalentModifierMask = []; editMenu.addItem(del)
        editMenu.addItem(NSMenuItem.separator())
        let frame = NSMenuItem(title: "Toggle Frame", action: #selector(toggleFrame), keyEquivalent: "b")
        frame.target = self; editMenu.addItem(frame)
        let rotate = NSMenuItem(title: "Rotate 90° CW", action: #selector(rotateImage), keyEquivalent: "r")
        rotate.target = self; editMenu.addItem(rotate)
        let grid = NSMenuItem(title: "Toggle Grid", action: #selector(toggleGrid), keyEquivalent: "g")
        grid.target = self; editMenu.addItem(grid)
        editMenu.addItem(NSMenuItem.separator())
        let front = NSMenuItem(title: "Bring to Front", action: #selector(doBringToFront), keyEquivalent: "]")
        front.target = self; editMenu.addItem(front)
        let back = NSMenuItem(title: "Send to Back", action: #selector(doSendToBack), keyEquivalent: "[")
        back.target = self; editMenu.addItem(back)
        let editItem = NSMenuItem(); editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(doZoomIn), keyEquivalent: "=")
        zoomIn.target = self; viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(doZoomOut), keyEquivalent: "-")
        zoomOut.target = self; viewMenu.addItem(zoomOut)
        viewMenu.addItem(NSMenuItem.separator())
        let zoomFit = NSMenuItem(title: "Zoom to Fit Width", action: #selector(doZoomFitWidth), keyEquivalent: "0")
        zoomFit.target = self; viewMenu.addItem(zoomFit)
        let zoomPage = NSMenuItem(title: "Zoom to Fit Page", action: #selector(doZoomFitPage), keyEquivalent: "0")
        zoomPage.target = self; zoomPage.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(zoomPage)
        let zoomActual = NSMenuItem(title: "Actual Size", action: #selector(doZoomActualSize), keyEquivalent: "1")
        zoomActual.target = self; viewMenu.addItem(zoomActual)
        let viewItem = NSMenuItem(); viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    // ── Menu actions ──

    @objc func pasteImage() { doc.pasteImage() }
    @objc func savePDF() { doc.exportPDF() }
    @objc func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        doc.loadPDF(from: url)
        relayout()
        DispatchQueue.main.async { [self] in
            doc.scrollToVisible(doc.pageRect(for: 0))
        }
    }
    @objc func deleteSelected() { doc.deleteSelected() }
    @objc func toggleFrame() { doc.toggleFrame() }
    @objc func duplicateSelected() { doc.duplicateSelected() }
    @objc func doUndo() { doc.undo() }
    @objc func doRedo() { doc.redo() }
    @objc func doBringToFront() { doc.bringToFront() }
    @objc func doSendToBack() { doc.sendToBack() }

    @objc func addPage() {
        doc.pushUndo(); doc.addPage(); relayout()
        DispatchQueue.main.async { [self] in
            doc.scrollToVisible(doc.pageRect(for: doc.numPages - 1))
        }
    }

    @objc func removePage() { doc.removePage(); relayout() }
    @objc func toggleOrientation() { doc.toggleOrientation(); relayout() }

    // ── Zoom ──

    private var zoomLabel: NSTextField?
    private var zoomFadeTimer: Timer?

    private func applyZoom(_ newZoom: CGFloat) {
        let clamped = min(4.0, max(0.25, newZoom))
        guard abs(clamped - doc.zoomLevel) > 0.001 else { return }

        // Always use current viewport center as focal point
        let clip = scrollView.contentView.bounds
        let viewCenter = NSPoint(x: clip.midX, y: clip.midY)
        let a4Focal = doc.toA4(viewCenter)

        doc.zoomLevel = clamped
        relayout()

        // Scroll so the same A4 point stays at viewport center after zoom
        let newScreen = doc.toScreen(a4Focal)
        let newClip = scrollView.contentView.bounds
        let ox = newScreen.x - newClip.width / 2
        let oy = newScreen.y - newClip.height / 2
        scrollView.contentView.scroll(to: NSPoint(
            x: max(0, min(ox, doc.frame.width - newClip.width)),
            y: max(0, min(oy, doc.frame.height - newClip.height))
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        showZoomLabel()
    }

    private func showZoomLabel() {
        let pct = Int(round(doc.zoomLevel * 100))
        if zoomLabel == nil {
            let lbl = NSTextField(labelWithString: "")
            lbl.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            lbl.textColor = .secondaryLabelColor
            lbl.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
            lbl.isBezeled = false; lbl.isEditable = false
            lbl.drawsBackground = true
            lbl.wantsLayer = true
            lbl.layer?.cornerRadius = 4
            scrollView.addSubview(lbl)
            zoomLabel = lbl
        }
        zoomLabel!.stringValue = "  \(pct)%  "
        zoomLabel!.sizeToFit()
        let sv = scrollView.bounds
        zoomLabel!.frame.origin = NSPoint(
            x: sv.maxX - zoomLabel!.frame.width - 12,
            y: sv.maxY - zoomLabel!.frame.height - 12
        )
        zoomLabel!.alphaValue = 1
        zoomLabel!.isHidden = false

        zoomFadeTimer?.invalidate()
        zoomFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.zoomLabel?.animator().alphaValue = 0
            } completionHandler: {
                self?.zoomLabel?.isHidden = true
            }
        }
    }

    @objc func doZoomIn() { applyZoom(doc.zoomLevel * 1.25) }
    @objc func doZoomOut() { applyZoom(doc.zoomLevel / 1.25) }

    @objc func doZoomFitWidth() { applyZoom(1.0) }

    @objc func doZoomFitPage() {
        // Zoom so an entire page (width + height) fits in the viewport
        let clipH = scrollView.contentView.bounds.height
        let clipW = scrollView.contentView.bounds.width
        // At zoom=1, page fills clipW - 2*pad in width. We need height to fit too.
        let pageAspect = doc.PW / doc.PH
        let availableH = clipH - doc.pad * 2
        // Page screen dimensions at zoom z: width = (clipW*z - 2*pad), height = width / pageAspect
        // We want height <= availableH and width <= availableW (at zoom=1 baseline)
        // Actually: at zoom z, pageW = (clipW*z - 2*pad), pageH = pageW * PH/PW
        // We want pageH <= clipH - 2*pad → (clipW*z - 2*pad) * PH/PW <= clipH - 2*pad
        // z <= (availableH * PW/PH + 2*pad) / clipW
        let zForHeight = (availableH * pageAspect + doc.pad * 2) / clipW
        let zForWidth: CGFloat = 1.0  // zoom=1 already fits width
        let z = min(zForWidth, zForHeight)
        applyZoom(z)
    }

    @objc func doZoomActualSize() {
        // 1 A4 point = 1 screen point → scale should equal 1.0
        // scale = pageW / PW = (contentW * zoom - 2*pad) / PW
        // We want scale = 1 → contentW * zoom - 2*pad = PW → zoom = (PW + 2*pad) / contentW
        let contentW = scrollView.contentView.bounds.width
        let z = (doc.PW + doc.pad * 2) / contentW
        applyZoom(z)
    }

    // ── Window delegate (unsaved changes) ──

    private var pendingTerminate = false
    private var closeConfirmed = false

    var hasContent: Bool {
        !doc.images.isEmpty || !doc.texts.isEmpty || !doc.lines.isEmpty
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed { return true }
        guard doc.isDirty && hasContent else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Do you want to save as PDF before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don\u{2019}t Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.doc.exportPDF()
                if !self.doc.isDirty {
                    self.closeConfirmed = true
                    self.window.close()
                }
            case .alertSecondButtonReturn:
                self.closeConfirmed = true
                self.window.close()
            default:
                self.pendingTerminate = false  // Cancel terminates the quit flow too
            }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closeConfirmed { return .terminateNow }
        guard doc.isDirty && hasContent else { return .terminateNow }
        pendingTerminate = true
        window.performClose(nil)
        return .terminateCancel
    }

    func windowWillClose(_ notification: Notification) {
        if pendingTerminate {
            pendingTerminate = false
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Main
// ─────────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
