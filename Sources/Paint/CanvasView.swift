import AppKit
import SwiftUI
import Combine

/// Weak global handle so the model / keyboard layer can reach the live canvas.
@MainActor
enum CanvasHolder {
    static weak var view: DocumentNSView?
}

// MARK: - Interaction state

private enum DragMode: Equatable {
    case stroke, erase, line, shape, curve, textBox, layerMove
    case selRect, selFree, selMove, selScale
    case polyFirst
    case canvasResize(String) // "e" | "s" | "se"
}

private struct DragState {
    var mode: DragMode
    var rightButton = false
    var start = CGPoint.zero
    var last = CGPoint.zero
    var end: CGPoint?
    var rect: CGRect?
    var shiftDown = false
    var strokeLayer: Layer?
    var pathPts: [CGPoint] = []
    var selHandle = -1
    var selOrig = CGRect.zero
    var moveOffset = CGPoint.zero
    var layerMoveBase: CGImage?
    var layerMoveDelta = CGPoint.zero
    var resizeStartSize = CGSize.zero
    var resizeNewSize = CGSize.zero
}

private struct CurveState {
    var p0: CGPoint
    var p1: CGPoint
    var c1: CGPoint?
    var c2: CGPoint?
    var phase = 0
    var right = false
}

// MARK: - Document view

@MainActor
final class DocumentNSView: NSView {
    weak var model: PaintModel?
    private var cancellables: Set<AnyCancellable> = []

    private var drag: DragState?
    private var curveState: CurveState?
    private var polyPts: [CGPoint]?
    private var polyRight = false
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?
    private var airTimer: Timer?
    private var hoverDoc: CGPoint?
    private var pendingFocus: (doc: CGPoint, clipOffset: CGPoint)?

    // text tool
    private var textView: PaintTextView?
    private var textOrigin: CGPoint = .zero // doc coords
    private var textBoxSizeDoc: CGSize?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: PaintModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        CanvasHolder.view = self

        model.$canvasRevision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
        model.$docSizeRevision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateDocumentFrame()
                self?.restoreZoomFocus()
                self?.styleTextView() // keep an open text editor scaled to the zoom
                self?.needsDisplay = true
            }
            .store(in: &cancellables)
        model.$tool
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.commitActiveText()
                self?.cancelTransient()
            }
            .store(in: &cancellables)
        model.$shapeId
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // switching shapes abandons an in-progress curve/polygon
                self?.cancelTransient()
            }
            .store(in: &cancellables)
        model.$textStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.styleTextView() }
            .store(in: &cancellables)
        model.$color1
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.styleTextView() }
            .store(in: &cancellables)
        model.$rulersOn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsDisplay = true
            }
            .store(in: &cancellables)

        model.zoomFocusRequest = { [weak self] docPt in
            self?.recordZoomFocus(docPt)
        }

        antsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.model else { return }
                if m.selection != nil {
                    self.antsPhase = (self.antsPhase + 0.4).truncatingRemainder(dividingBy: 7)
                    self.needsDisplay = true
                }
            }
        }
        if let antsTimer {
            RunLoop.main.add(antsTimer, forMode: .common)
        }

        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        antsTimer?.invalidate()
        airTimer?.invalidate()
    }

    // MARK: geometry

    private var zoom: CGFloat { model?.zoom ?? 1 }

    var canvasOrigin: CGPoint {
        guard let m = model else { return .zero }
        let cw = CGFloat(m.docWidth) * zoom
        return CGPoint(x: max(48, (bounds.width - cw) / 2), y: 24)
    }

    var canvasRectInView: CGRect {
        guard let m = model else { return .zero }
        return CGRect(
            origin: canvasOrigin,
            size: CGSize(width: CGFloat(m.docWidth) * zoom, height: CGFloat(m.docHeight) * zoom)
        )
    }

    func docPoint(fromView p: CGPoint) -> CGPoint {
        let o = canvasOrigin
        return CGPoint(x: (p.x - o.x) / zoom, y: (p.y - o.y) / zoom)
    }

    func viewPoint(fromDoc p: CGPoint) -> CGPoint {
        let o = canvasOrigin
        return CGPoint(x: o.x + p.x * zoom, y: o.y + p.y * zoom)
    }

    private func clampDoc(_ p: CGPoint) -> CGPoint {
        guard let m = model else { return p }
        return CGPoint(
            x: min(CGFloat(m.docWidth), max(0, p.x)),
            y: min(CGFloat(m.docHeight), max(0, p.y))
        )
    }

    func updateDocumentFrame() {
        guard let m = model, let scroll = enclosingScrollView else { return }
        let cw = CGFloat(m.docWidth) * zoom
        let ch = CGFloat(m.docHeight) * zoom
        let clip = scroll.contentView.bounds.size
        setFrameSize(CGSize(width: max(clip.width, cw + 96), height: max(clip.height, ch + 72)))
    }

    // MARK: zoom focus

    private func recordZoomFocus(_ docPt: CGPoint?) {
        guard let scroll = enclosingScrollView else { return }
        let visible = scroll.contentView.bounds
        let dp = docPt ?? docPoint(fromView: CGPoint(x: visible.midX, y: visible.midY))
        let vp = viewPoint(fromDoc: dp)
        pendingFocus = (dp, CGPoint(x: vp.x - visible.origin.x, y: vp.y - visible.origin.y))
    }

    private func restoreZoomFocus() {
        guard let focus = pendingFocus, let scroll = enclosingScrollView else { return }
        pendingFocus = nil
        let vp = viewPoint(fromDoc: focus.doc)
        var origin = CGPoint(x: vp.x - focus.clipOffset.x, y: vp.y - focus.clipOffset.y)
        let clip = scroll.contentView.bounds.size
        origin.x = min(max(0, origin.x), max(0, frame.width - clip.width))
        origin.y = min(max(0, origin.y), max(0, frame.height - clip.height))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func fitToWindow() {
        guard let m = model, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView.bounds.size
        let z = min((clip.width - 100) / CGFloat(m.docWidth), (clip.height - 80) / CGFloat(m.docHeight), PaintModel.maxZoom)
        m.setZoom(max(PaintModel.minZoom, z))
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext, let m = model else { return }

        // workspace background
        g.setFillColor(CGColor(srgbRed: 0x41 / 255, green: 0x41 / 255, blue: 0x41 / 255, alpha: 1))
        g.fill(bounds)

        let cr = canvasRectInView

        // canvas shadow
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(gray: 0, alpha: 0.35))
        g.setFillColor(CGColor(gray: 0.2, alpha: 1))
        g.fill(cr)
        g.restoreGState()

        // checkerboard (transparency backdrop)
        g.saveGState()
        g.clip(to: cr)
        drawCheckerboard(g, in: cr)

        // layers, doc-space transform
        g.translateBy(x: cr.origin.x, y: cr.origin.y)
        g.scaleBy(x: zoom, y: zoom)
        g.interpolationQuality = zoom > 1 ? .none : .high

        let moveDrag = (drag?.mode == .layerMove) ? drag : nil
        for (idx, layer) in m.layers.enumerated() where layer.visible {
            if let d = moveDrag, idx == m.activeLayerIndex, let img = d.layerMoveBase {
                g.saveGState()
                g.setAlpha(layer.opacity)
                drawImageTopLeft(
                    g,
                    img,
                    in: CGRect(
                        x: d.layerMoveDelta.x,
                        y: d.layerMoveDelta.y,
                        width: CGFloat(m.docWidth),
                        height: CGFloat(m.docHeight)
                    )
                )
                g.restoreGState()
                continue
            }
            guard let img = layer.image() else { continue }
            g.saveGState()
            g.setAlpha(layer.opacity)
            drawImageTopLeft(g, img, in: CGRect(x: 0, y: 0, width: m.docWidth, height: m.docHeight))
            g.restoreGState()
        }

        if m.rulersOn {
            drawRulerGuides(g, m)
        }

        // live stroke preview
        if let d = drag, d.mode == .stroke || d.mode == .erase, let sl = d.strokeLayer, let img = sl.image() {
            g.saveGState()
            let alpha: CGFloat = m.tool == .brush ? m.brushType.strokeAlpha : 1
            g.setAlpha(alpha)
            drawImageTopLeft(g, img, in: CGRect(x: 0, y: 0, width: m.docWidth, height: m.docHeight))
            g.restoreGState()
        }

        drawToolPreviews(g, m)
        drawSelection(g, m)
        if m.gridOn { drawGrid(g, m) }
        drawEraserRing(g, m)

        g.restoreGState() // undo doc transform + canvas clip

        drawCanvasHandles(g, cr)
        drawResizeGhost(g, cr)
    }

    private func drawCheckerboard(_ g: CGContext, in rect: CGRect) {
        let s: CGFloat = 8
        g.setFillColor(CGColor(srgbRed: 0.23, green: 0.23, blue: 0.23, alpha: 1))
        g.fill(rect)
        g.setFillColor(CGColor(srgbRed: 0.27, green: 0.27, blue: 0.27, alpha: 1))
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX {
                g.fill(CGRect(x: x, y: y, width: min(s, rect.maxX - x), height: min(s, rect.maxY - y)))
                x += s * 2
            }
            y += s
            row += 1
        }
    }

    // doc-space (assumes doc transform active)
    private func drawToolPreviews(_ g: CGContext, _ m: PaintModel) {
        if let d = drag {
            switch d.mode {
            case .line:
                if let end = d.end {
                    strokeAndFillPath(g, m, linePath(from: d.start, to: end, shift: d.shiftDown), isOpen: true, right: d.rightButton)
                }
            case .textBox:
                if let r = d.rect {
                    drawMarquee(g, rect: r)
                }
            case .shape:
                if let r = d.rect {
                    let shape = ShapeLibrary.byId(m.shapeId)
                    strokeAndFillPath(g, m, shape.path(in: r), isOpen: shape.isOpen, right: d.rightButton)
                }
            case .selRect:
                if let r = d.rect { drawMarquee(g, rect: r) }
            case .selFree:
                drawMarquee(g, pts: d.pathPts, close: false)
            case .polyFirst:
                if let end = d.end {
                    strokeAndFillPath(g, m, linePath(from: d.start, to: end, shift: false), isOpen: true, right: d.rightButton)
                }
            default: break
            }
        }
        if m.tool == .sticker, drag == nil {
            drawStickerGhost(g, m)
        }
        if let st = curveState {
            strokeAndFillPath(g, m, curvePath(st), isOpen: true, right: st.right)
        }
        if let pts = polyPts, drag == nil {
            let p = CGMutablePath()
            p.addLines(between: pts)
            if let hover = hoverDoc { p.addLine(to: hover) }
            strokeAndFillPath(g, m, p, isOpen: true, right: polyRight)
        }
    }

    private func drawStickerGhost(_ g: CGContext, _ m: PaintModel) {
        guard let raw = hoverDoc else { return }
        guard raw.x >= 0, raw.y >= 0, raw.x <= CGFloat(m.docWidth), raw.y <= CGFloat(m.docHeight) else { return }

        let p = clampDoc(raw)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64)]
        let attr = NSAttributedString(string: m.stickerChar, attributes: attrs)
        let size = attr.size()

        g.saveGState()
        g.setAlpha(0.45)
        let ns = NSGraphicsContext(cgContext: g, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attr.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        g.restoreGState()
    }

    func strokeAndFillPath(_ g: CGContext, _ m: PaintModel, _ path: CGPath, isOpen: Bool, right: Bool) {
        let strokeCol = right ? m.color2 : m.color1
        let fillCol = right ? m.color1 : m.color2
        g.saveGState()
        g.setLineJoin(.round)
        g.setLineCap(.round)
        if !isOpen && m.fillStyle != .none {
            paintFill(g, path: path, style: m.fillStyle, color: fillCol)
        }
        if m.outlineStyle != .none {
            paintStroke(g, path: path, style: m.outlineStyle, width: m.sizes["shape"] ?? 3, color: strokeCol)
        }
        g.restoreGState()
    }

    private func paintFill(_ g: CGContext, path: CGPath, style: FillPattern, color: RGB) {
        g.saveGState()
        switch style {
        case .none:
            break
        case .solid:
            g.setAlpha(1)
            g.setFillColor(color.cgColor)
            g.addPath(path)
            g.fillPath()
        default:
            fillPathWithHalftone(g, path: path, style: style, color: color)
        }
        g.restoreGState()
    }

    private func fillPathWithHalftone(_ g: CGContext, path: CGPath, style: FillPattern, color: RGB) {
        guard let pattern = halftonePattern(style) else { return }
        g.saveGState()
        g.addPath(path)
        g.clip()
        g.setFillColor(color.cgColor)
        let box = path.boundingBoxOfPath.integral.insetBy(dx: -1, dy: -1)
        let minX = Int(floor(box.minX))
        let maxX = Int(ceil(box.maxX))
        let minY = Int(floor(box.minY))
        let maxY = Int(ceil(box.maxY))
        for y in minY...maxY {
            for x in minX...maxX {
                if pattern[y & 7][x & 7] {
                    g.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
                }
            }
        }
        g.restoreGState()
    }

    private func halftonePattern(_ style: FillPattern) -> [[Bool]]? {
        switch style {
        case .none, .solid:
            return nil
        case .pct12:
            return patternFromRule { x, y in x % 4 == 0 && y % 4 == 0 }
        case .pct25:
            return patternFromRule { x, y in (x % 2 == 0) && (y % 2 == 0) }
        case .pct50:
            return patternFromRule { x, y in (x + y) % 2 == 0 }
        case .pct75:
            return patternFromRule { x, y in !((x % 2 == 1) && (y % 2 == 1)) }
        case .horizontal:
            return patternFromRule { _, y in y % 2 == 0 }
        case .vertical:
            return patternFromRule { x, _ in x % 2 == 0 }
        case .cross:
            return patternFromRule { x, y in x % 2 == 0 || y % 2 == 0 }
        case .diagDown:
            return patternFromRule { x, y in ((x - y) % 4 + 4) % 4 == 0 }
        case .diagUp:
            return patternFromRule { x, y in (x + y) % 4 == 0 }
        case .diagCross:
            return patternFromRule { x, y in ((((x - y) % 4 + 4) % 4) == 0) || ((x + y) % 4 == 0) }
        }
    }

    private func patternFromRule(_ rule: (Int, Int) -> Bool) -> [[Bool]] {
        var out = Array(repeating: Array(repeating: false, count: 8), count: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                out[y][x] = rule(x, y)
            }
        }
        return out
    }

    private func paintStroke(_ g: CGContext, path: CGPath, style: OutlineStyle, width: CGFloat, color: RGB) {
        g.saveGState()
        g.setStrokeColor(color.cgColor)
        switch style {
        case .none:
            break
        case .solid:
            g.setAlpha(1)
            g.setLineWidth(width)
            g.addPath(path)
            g.strokePath()
        }
        g.restoreGState()
    }

    private func drawMarquee(_ g: CGContext, rect: CGRect) {
        drawAntsPath(g) { $0.addRect(rect) }
    }

    private func drawMarquee(_ g: CGContext, pts: [CGPoint], close: Bool) {
        guard pts.count > 1 else { return }
        drawAntsPath(g) { p in
            p.addLines(between: pts)
            if close { p.closeSubpath() }
        }
    }

    private func drawAntsPath(_ g: CGContext, _ build: (CGMutablePath) -> Void) {
        let p = CGMutablePath()
        build(p)
        g.saveGState()
        g.setLineWidth(max(1 / zoom, 0.5))
        let dash: [CGFloat] = [4 / zoom, 3 / zoom]
        g.setStrokeColor(CGColor(gray: 1, alpha: 1))
        g.setLineDash(phase: -antsPhase / zoom, lengths: dash)
        g.addPath(p)
        g.strokePath()
        g.setStrokeColor(CGColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1))
        g.setLineDash(phase: -antsPhase / zoom + 4 / zoom, lengths: dash)
        g.addPath(p)
        g.strokePath()
        g.restoreGState()
    }

    private func drawSelection(_ g: CGContext, _ m: PaintModel) {
        guard let sel = m.selection else { return }
        if let floating = sel.floating, let img = floating.image() {
            drawImageTopLeft(g, img, in: sel.rect)
        }
        if let pts = sel.freePath, sel.floating == nil {
            drawMarquee(g, pts: pts, close: true)
        } else {
            drawMarquee(g, rect: sel.rect)
        }
        // handles
        let s = 7 / zoom
        g.setFillColor(CGColor(gray: 1, alpha: 1))
        g.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
        g.setLineWidth(1 / zoom)
        for pt in selHandlePoints(sel.rect) {
            let r = CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)
            g.fill(r)
            g.stroke(r)
        }
    }

    private func selHandlePoints(_ r: CGRect) -> [CGPoint] {
        [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ]
    }

    private func drawGrid(_ g: CGContext, _ m: PaintModel) {
        g.saveGState()
        g.setStrokeColor(CGColor(gray: 0.5, alpha: 0.55))
        g.setLineWidth(1 / zoom)
        let step: CGFloat = 10
        let p = CGMutablePath()
        var x = step
        while x < CGFloat(m.docWidth) {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: CGFloat(m.docHeight)))
            x += step
        }
        var y = step
        while y < CGFloat(m.docHeight) {
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: CGFloat(m.docWidth), y: y))
            y += step
        }
        g.addPath(p)
        g.strokePath()
        g.restoreGState()
    }

    private func drawRulerGuides(_ g: CGContext, _ m: PaintModel) {
        g.saveGState()
        g.setStrokeColor(CGColor(gray: 0.8, alpha: 0.18))
        g.setLineWidth(1 / zoom)
        let major = rulerMajorStep(for: m.zoom)
        let p = CGMutablePath()

        var x = major
        while x < CGFloat(m.docWidth) {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: CGFloat(m.docHeight)))
            x += major
        }

        var y = major
        while y < CGFloat(m.docHeight) {
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: CGFloat(m.docWidth), y: y))
            y += major
        }

        g.addPath(p)
        g.strokePath()
        g.restoreGState()
    }

    private func rulerMajorStep(for zoom: CGFloat) -> CGFloat {
        for c in [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000] where CGFloat(c) * zoom >= 40 {
            return CGFloat(c)
        }
        return 1000
    }

    private func drawEraserRing(_ g: CGContext, _ m: PaintModel) {
        guard m.tool == .eraser, let p = drag?.last ?? hoverDoc else { return }
        let s = (m.sizes["eraser"] ?? 24) / 2
        g.saveGState()
        g.setLineWidth(1 / zoom)
        g.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        g.strokeEllipse(in: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2))
        g.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        let s2 = s + 1 / zoom
        g.strokeEllipse(in: CGRect(x: p.x - s2, y: p.y - s2, width: s2 * 2, height: s2 * 2))
        g.restoreGState()
    }

    private func drawCanvasHandles(_ g: CGContext, _ cr: CGRect) {
        let pts: [CGPoint] = [
            CGPoint(x: cr.minX, y: cr.minY), CGPoint(x: cr.midX, y: cr.minY), CGPoint(x: cr.maxX, y: cr.minY),
            CGPoint(x: cr.minX, y: cr.midY), CGPoint(x: cr.maxX, y: cr.midY),
            CGPoint(x: cr.minX, y: cr.maxY), CGPoint(x: cr.midX, y: cr.maxY), CGPoint(x: cr.maxX, y: cr.maxY),
        ]
        g.setFillColor(CGColor(gray: 1, alpha: 1))
        g.setStrokeColor(CGColor(gray: 0.42, alpha: 1))
        g.setLineWidth(1)
        for p in pts {
            let r = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            g.fill(r)
            g.stroke(r)
        }
    }

    private func drawResizeGhost(_ g: CGContext, _ cr: CGRect) {
        guard let d = drag, case .canvasResize = d.mode else { return }
        let r = CGRect(origin: cr.origin, size: CGSize(width: d.resizeNewSize.width * zoom, height: d.resizeNewSize.height * zoom))
        g.saveGState()
        g.setStrokeColor(CGColor(srgbRed: 0.62, green: 0.8, blue: 1, alpha: 1))
        g.setLineWidth(1)
        g.setLineDash(phase: 0, lengths: [4, 3])
        g.stroke(r)
        g.restoreGState()
    }

    // MARK: hit testing

    private func hitCanvasHandle(_ viewPt: CGPoint) -> String? {
        let cr = canvasRectInView
        let handles: [(String, CGPoint)] = [
            ("e", CGPoint(x: cr.maxX, y: cr.midY)),
            ("s", CGPoint(x: cr.midX, y: cr.maxY)),
            ("se", CGPoint(x: cr.maxX, y: cr.maxY)),
        ]
        for (id, p) in handles {
            if abs(viewPt.x - p.x) <= 5 && abs(viewPt.y - p.y) <= 5 { return id }
        }
        return nil
    }

    private func hitSelHandle(_ docPt: CGPoint) -> Int {
        guard let sel = model?.selection else { return -1 }
        let tol = 6 / zoom
        for (i, p) in selHandlePoints(sel.rect).enumerated() {
            if abs(docPt.x - p.x) <= tol && abs(docPt.y - p.y) <= tol { return i }
        }
        return -1
    }

    private func insideSelection(_ docPt: CGPoint) -> Bool {
        model?.selection?.rect.contains(docPt) ?? false
    }

    // MARK: shape paths

    private func normRect(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var x1 = b.x, y1 = b.y
        if square {
            let dx = b.x - a.x, dy = b.y - a.y
            let m = max(abs(dx), abs(dy))
            x1 = a.x + (dx < 0 ? -m : m)
            y1 = a.y + (dy < 0 ? -m : m)
        }
        return CGRect(x: min(a.x, x1), y: min(a.y, y1), width: abs(x1 - a.x), height: abs(y1 - a.y))
    }

    private func linePath(from a: CGPoint, to b: CGPoint, shift: Bool) -> CGPath {
        var end = b
        if shift {
            let dx = b.x - a.x, dy = b.y - a.y
            let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let d = hypot(dx, dy)
            end = CGPoint(x: a.x + cos(ang) * d, y: a.y + sin(ang) * d)
        }
        let p = CGMutablePath()
        p.move(to: a)
        p.addLine(to: end)
        return p
    }

    private func curvePath(_ st: CurveState) -> CGPath {
        let p = CGMutablePath()
        p.move(to: st.p0)
        if let c1 = st.c1, let c2 = st.c2 {
            p.addCurve(to: st.p1, control1: c1, control2: c2)
        } else if let c1 = st.c1 {
            p.addQuadCurve(to: st.p1, control: c1)
        } else {
            p.addLine(to: st.p1)
        }
        return p
    }

    // MARK: mouse events

    override func mouseDown(with e: NSEvent) { handleDown(e, right: false) }
    override func rightMouseDown(with e: NSEvent) { handleDown(e, right: true) }
    override func mouseDragged(with e: NSEvent) { handleDrag(e) }
    override func rightMouseDragged(with e: NSEvent) { handleDrag(e) }
    override func mouseUp(with e: NSEvent) { handleUp(e) }
    override func rightMouseUp(with e: NSEvent) { handleUp(e) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            guard let m = model else { return }
            let viewPt = convert(e.locationInWindow, from: nil)
            m.zoomStep(e.scrollingDeltaY > 0 ? 1 : -1, focusDocPoint: docPoint(fromView: viewPt))
        } else {
            super.scrollWheel(with: e)
        }
    }

    private func handleDown(_ e: NSEvent, right: Bool) {
        guard let m = model else { return }
        // a second button pressed mid-drag must not restart the gesture
        if drag != nil { return }
        window?.makeFirstResponder(self)
        let viewPt = convert(e.locationInWindow, from: nil)
        let rawDoc = docPoint(fromView: viewPt)
        let p = clampDoc(rawDoc)

        // canvas resize handles first (they sit on the edge)
        if !right, let handle = hitCanvasHandle(viewPt) {
            var d = DragState(mode: .canvasResize(handle))
            d.resizeStartSize = m.docSize
            d.resizeNewSize = m.docSize
            d.start = rawDoc
            drag = d
            return
        }

        // click landed on the text editor → let it handle
        if let tv = textView, tv.frame.contains(viewPt) { return }
        if textView != nil { commitActiveText(); return }

        // clicks in the gray stage around the canvas do nothing (like Paint)
        if rawDoc.x < 0 || rawDoc.y < 0 || rawDoc.x > CGFloat(m.docWidth) || rawDoc.y > CGFloat(m.docHeight) {
            return
        }

        switch m.tool {
        case .text:
            drag = DragState(
                mode: .textBox,
                rightButton: right,
                start: p,
                last: p,
                rect: CGRect(x: p.x, y: p.y, width: 1, height: 1)
            )
            needsDisplay = true
            return
        case .picker:
            if let c = m.pickColor(at: p) { m.setColor(well: right ? 2 : 1, c) }
            m.setTool(m.previousTool == .picker ? .pencil : m.previousTool)
            return
        case .fill:
            m.floodFill(at: p, color: right ? m.color2 : m.color1)
            return
        case .magnifier:
            m.zoomStep(right ? -1 : 1, focusDocPoint: p)
            return
        case .move:
            var d = DragState(mode: .layerMove, rightButton: right, start: p, last: p)
            d.layerMoveBase = m.activeLayer.image()
            d.layerMoveDelta = .zero
            drag = d
            needsDisplay = true
            return
        case .sticker:
            m.stampSticker(at: p)
            return
        case .shape where m.shapeId == "curve":
            if curveState == nil { curveState = CurveState(p0: p, p1: p, right: right) }
            drag = DragState(mode: .curve, rightButton: right, start: p, last: p)
            return
        case .shape where m.shapeId == "polygon":
            handlePolygonDown(p, right: right, clickCount: e.clickCount)
            return
        default:
            break
        }

        var d = DragState(mode: .stroke, rightButton: right, start: p, last: p)
        switch m.tool {
        case .pencil, .brush:
            d.mode = .stroke
            d.strokeLayer = Layer(w: m.docWidth, h: m.docHeight)
            let color = right ? m.color2 : m.color1
            if m.tool == .brush && m.brushType == .airbrush {
                startAirbrush(d: &d, color: color)
            } else {
                BrushEngine.stampSegment(ctx: d.strokeLayer!.ctx, from: p, to: p, tool: m.tool, brush: m.brushType, size: m.currentSize, color: color)
            }
        case .eraser:
            d.mode = .erase
            eraseSegment(from: p, to: p)
        case .shape:
            d.mode = m.shapeId == "line" ? .line : .shape
        case .move:
            d.mode = .layerMove
        case .select:
            let hi = hitSelHandle(p)
            if hi >= 0 {
                m.liftSelection()
                d.mode = .selScale
                d.selHandle = hi
                d.selOrig = m.selection?.rect ?? .zero
            } else if insideSelection(p) {
                m.liftSelection()
                d.mode = .selMove
                if let sel = m.selection {
                    d.moveOffset = CGPoint(x: p.x - sel.rect.origin.x, y: p.y - sel.rect.origin.y)
                }
            } else {
                if m.selection != nil { m.dropSelection() }
                d.mode = m.selectMode == .free ? .selFree : .selRect
                d.pathPts = [p]
            }
        default:
            return
        }
        drag = d
        needsDisplay = true
    }

    private func handleDrag(_ e: NSEvent) {
        guard let m = model else { return }
        let viewPt = convert(e.locationInWindow, from: nil)
        let rawDoc = docPoint(fromView: viewPt)
        let p = clampDoc(rawDoc)
        updateCursorStatus(rawDoc)

        guard var d = drag else { return }
        d.shiftDown = e.modifierFlags.contains(.shift)

        switch d.mode {
        case .stroke:
            if m.tool == .brush && m.brushType == .airbrush {
                if let sl = d.strokeLayer {
                    let color = d.rightButton ? m.color2 : m.color1
                    BrushEngine.spraySegment(sl.ctx, from: d.last, to: p, size: m.currentSize, color: color)
                }
                d.last = p
            } else if let sl = d.strokeLayer {
                let color = d.rightButton ? m.color2 : m.color1
                BrushEngine.stampSegment(ctx: sl.ctx, from: d.last, to: p, tool: m.tool, brush: m.brushType, size: m.currentSize, color: color)
                d.last = p
            }
        case .erase:
            eraseSegment(from: d.last, to: p)
            d.last = p
        case .line:
            d.end = p
            m.selectionText = "\(Int(abs(p.x - d.start.x))) × \(Int(abs(p.y - d.start.y)))px"
        case .textBox:
            d.rect = normRect(d.start, p, square: false)
            if let r = d.rect {
                m.selectionText = "\(Int(r.width)) × \(Int(r.height))px"
            }
        case .shape:
            d.rect = normRect(d.start, p, square: d.shiftDown)
            if let r = d.rect { m.selectionText = "\(Int(r.width)) × \(Int(r.height))px" }
        case .layerMove:
            d.layerMoveDelta = CGPoint(x: (p.x - d.start.x).rounded(), y: (p.y - d.start.y).rounded())
        case .curve:
            if var st = curveState {
                switch st.phase {
                case 0: st.p1 = p
                case 1: st.c1 = p
                default: st.c2 = p
                }
                curveState = st
            }
        case .selRect:
            d.rect = normRect(d.start, p, square: d.shiftDown)
            if let r = d.rect { m.selectionText = "\(Int(r.width)) × \(Int(r.height))px" }
        case .selFree:
            d.pathPts.append(p)
        case .selMove:
            if var sel = m.selection {
                sel.rect.origin = CGPoint(x: (p.x - d.moveOffset.x).rounded(), y: (p.y - d.moveOffset.y).rounded())
                m.selection = sel
            }
        case .selScale:
            if var sel = m.selection {
                let o = d.selOrig
                var x0 = o.minX, y0 = o.minY, x1 = o.maxX, y1 = o.maxY
                switch d.selHandle {
                case 0: x0 = p.x; y0 = p.y
                case 1: y0 = p.y
                case 2: x1 = p.x; y0 = p.y
                case 3: x0 = p.x
                case 4: x1 = p.x
                case 5: x0 = p.x; y1 = p.y
                case 6: y1 = p.y
                default: x1 = p.x; y1 = p.y
                }
                sel.rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: max(1, abs(x1 - x0)), height: max(1, abs(y1 - y0)))
                m.selection = sel
                m.selectionText = "\(Int(sel.rect.width)) × \(Int(sel.rect.height))px"
            }
        case .polyFirst:
            d.end = p
        case .canvasResize(let dir):
            let dx = rawDoc.x - d.start.x
            let dy = rawDoc.y - d.start.y
            var w = d.resizeStartSize.width
            var h = d.resizeStartSize.height
            if dir.contains("e") { w = max(1, (d.resizeStartSize.width + dx).rounded()) }
            if dir.contains("s") { h = max(1, (d.resizeStartSize.height + dy).rounded()) }
            d.resizeNewSize = CGSize(width: w, height: h)
        }
        drag = d
        needsDisplay = true
    }

    private func handleUp(_ e: NSEvent) {
        guard let m = model, var d = drag else { return }
        let viewPt = convert(e.locationInWindow, from: nil)
        let p = clampDoc(docPoint(fromView: viewPt))

        switch d.mode {
        case .stroke:
            stopAirbrush()
            if let sl = d.strokeLayer, let img = sl.image() {
                let ctx = m.activeLayer.ctx
                ctx.saveGState()
                ctx.setAlpha(m.tool == .brush ? m.brushType.strokeAlpha : 1)
                drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: m.docWidth, height: m.docHeight))
                ctx.restoreGState()
                m.commit()
            }
        case .erase:
            m.commit()
        case .line:
            if let end = d.end {
                let path = linePath(from: d.start, to: end, shift: d.shiftDown)
                strokeAndFillPath(m.activeLayer.ctx, m, path, isOpen: true, right: d.rightButton)
                m.commit()
            }
            m.selectionText = m.selection.map { "\(Int($0.rect.width)) × \(Int($0.rect.height))px" } ?? ""
        case .textBox:
            let rect = d.rect ?? CGRect(x: p.x, y: p.y, width: 0, height: 0)
            if rect.width >= 3 || rect.height >= 3 {
                startTextEditor(at: rect.origin, initialBoxSize: rect.size)
            } else {
                startTextEditor(at: p)
            }
            m.selectionText = ""
        case .shape:
            if let r = d.rect, r.width > 2 || r.height > 2 {
                let shape = ShapeLibrary.byId(m.shapeId)
                strokeAndFillPath(m.activeLayer.ctx, m, shape.path(in: r), isOpen: shape.isOpen, right: d.rightButton)
                m.commit()
            }
            m.selectionText = ""
        case .layerMove:
            if let base = d.layerMoveBase {
                applyLayerMove(baseImage: base, delta: d.layerMoveDelta)
                if d.layerMoveDelta != .zero {
                    m.commit()
                } else {
                    m.repaint()
                }
            }
        case .curve:
            if var st = curveState {
                switch st.phase {
                case 0:
                    st.phase = 1
                    curveState = st
                case 1:
                    st.c1 = p
                    st.phase = 2
                    curveState = st
                default:
                    st.c2 = p
                    strokeAndFillPath(m.activeLayer.ctx, m, curvePath(st), isOpen: true, right: st.right)
                    m.commit()
                    curveState = nil
                }
            }
        case .selRect:
            if let r = d.rect, r.width >= 2, r.height >= 2 {
                m.setSelection(Selection(rect: r.integral, floating: nil, freePath: nil))
            } else {
                m.selectionText = ""
            }
        case .selFree:
            if d.pathPts.count > 4 {
                let xs = d.pathPts.map(\.x), ys = d.pathPts.map(\.y)
                let r = CGRect(
                    x: xs.min()!, y: ys.min()!,
                    width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!
                )
                if r.width >= 2, r.height >= 2 {
                    m.setSelection(Selection(rect: r.integral, floating: nil, freePath: d.pathPts))
                }
            }
        case .selMove, .selScale:
            break
        case .polyFirst:
            if let end = d.end {
                polyPts = [d.start, end]
            } else {
                polyPts = [d.start]
            }
            polyRight = d.rightButton
            drag = nil
            needsDisplay = true
            return
        case .canvasResize:
            let s = d.resizeNewSize
            if s != d.resizeStartSize {
                m.resizeCanvas(width: Int(s.width), height: Int(s.height), stretch: false)
            }
        }
        drag = nil
        d.strokeLayer = nil
        needsDisplay = true
    }

    // MARK: polygon

    private func handlePolygonDown(_ p: CGPoint, right: Bool, clickCount: Int) {
        guard let m = model else { return }
        if polyPts == nil {
            drag = DragState(mode: .polyFirst, rightButton: right, start: p, last: p)
            return
        }
        guard var pts = polyPts else { return }
        let first = pts[0]
        let closeDist = hypot(p.x - first.x, p.y - first.y)
        if pts.count > 2 && (closeDist < 8 / zoom || clickCount >= 2) {
            finishPolygon(right: polyRight)
            return
        }
        pts.append(p)
        polyPts = pts
        needsDisplay = true
        _ = m
    }

    private func finishPolygon(right: Bool) {
        guard let m = model, let pts = polyPts, pts.count >= 3 else {
            polyPts = nil
            needsDisplay = true
            return
        }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        strokeAndFillPath(m.activeLayer.ctx, m, path, isOpen: false, right: right)
        m.commit()
        polyPts = nil
    }

    // MARK: eraser / airbrush

    private func eraseSegment(from a: CGPoint, to b: CGPoint) {
        guard let m = model else { return }
        let layer = m.activeLayer
        let ctx = layer.ctx
        ctx.saveGState()
        if layer.isBackground {
            ctx.setStrokeColor(m.color2.cgColor)
        } else {
            ctx.setBlendMode(.clear)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        }
        ctx.setLineWidth(m.sizes["eraser"] ?? 24)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: a)
        ctx.addLine(to: CGPoint(x: b.x + 0.01, y: b.y))
        ctx.strokePath()
        ctx.restoreGState()
        m.repaint()
    }

    private func applyLayerMove(baseImage: CGImage, delta: CGPoint) {
        guard let m = model else { return }
        let layer = m.activeLayer
        let ctx = layer.ctx
        let rect = CGRect(x: 0, y: 0, width: m.docWidth, height: m.docHeight)
        ctx.saveGState()
        if layer.isBackground {
            ctx.setBlendMode(.normal)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
        } else {
            ctx.setBlendMode(.clear)
            ctx.fill(rect)
            ctx.setBlendMode(.normal)
        }
        drawImageTopLeft(
            ctx,
            baseImage,
            in: CGRect(
                x: delta.x,
                y: delta.y,
                width: CGFloat(m.docWidth),
                height: CGFloat(m.docHeight)
            )
        )
        ctx.restoreGState()
    }

    private func startAirbrush(d: inout DragState, color: RGB) {
        guard let m = model, let sl = d.strokeLayer else { return }
        BrushEngine.sprayAt(sl.ctx, d.start, size: m.currentSize, color: color)
        airTimer?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.model, let d = self.drag, let sl = d.strokeLayer else { return }
                BrushEngine.sprayAt(sl.ctx, d.last, size: m.currentSize, color: d.rightButton ? m.color2 : m.color1)
                self.needsDisplay = true
            }
        }
        airTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAirbrush() {
        airTimer?.invalidate()
        airTimer = nil
    }

    // MARK: hover / cursor

    override func mouseMoved(with e: NSEvent) {
        let viewPt = convert(e.locationInWindow, from: nil)
        let rawDoc = docPoint(fromView: viewPt)
        hoverDoc = rawDoc
        updateCursorStatus(rawDoc)
        updateCursor(viewPt, rawDoc)
        guard let m = model else { return }
        if m.tool == .eraser { needsDisplay = true }
        if m.tool == .sticker { needsDisplay = true }
        if m.tool == .shape && (m.shapeId == "curve" || m.shapeId == "polygon") {
            if var st = curveState, st.phase > 0 {
                if st.phase == 1 { st.c1 = clampDoc(rawDoc) } else { st.c2 = clampDoc(rawDoc) }
                curveState = st
                needsDisplay = true
            }
            if polyPts != nil { needsDisplay = true }
        }
    }

    override func mouseExited(with e: NSEvent) {
        hoverDoc = nil
        model?.cursorText = ""
        if model?.tool == .eraser { needsDisplay = true }
        if model?.tool == .sticker { needsDisplay = true }
    }

    private func updateCursorStatus(_ rawDoc: CGPoint) {
        guard let m = model else { return }
        if rawDoc.x >= 0, rawDoc.y >= 0, rawDoc.x < CGFloat(m.docWidth), rawDoc.y < CGFloat(m.docHeight) {
            m.cursorText = "\(Int(rawDoc.x)), \(Int(rawDoc.y))px"
        } else {
            m.cursorText = ""
        }
    }

    private func updateCursor(_ viewPt: CGPoint, _ docPt: CGPoint) {
        guard let m = model else { return }
        if let h = hitCanvasHandle(viewPt) {
            switch h {
            case "e": NSCursor.resizeLeftRight.set()
            case "s": NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        guard canvasRectInView.contains(viewPt) else { NSCursor.arrow.set(); return }
        switch m.tool {
        case .text: NSCursor.iBeam.set()
        case .move:
            if drag?.mode == .layerMove {
                NSCursor.closedHand.set()
            } else {
                NSCursor.openHand.set()
            }
        case .select:
            let hi = hitSelHandle(docPt)
            if hi >= 0 {
                switch hi {
                case 1, 6: NSCursor.resizeUpDown.set()
                case 3, 4: NSCursor.resizeLeftRight.set()
                default: NSCursor.crosshair.set()
                }
            } else if insideSelection(docPt) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        default:
            NSCursor.crosshair.set()
        }
    }

    // MARK: text editor overlay

    private func startTextEditor(at p: CGPoint, initialBoxSize: CGSize? = nil) {
        guard let m = model else { return }
        commitActiveText()
        let tv = PaintTextView(frame: .zero)
        tv.isRichText = false
        tv.drawsBackground = false
        tv.insertionPointColor = m.color1.nsColor
        tv.allowsUndo = true
        tv.onEscape = { [weak self] in self?.cancelActiveText() }
        textOrigin = p
        textBoxSizeDoc = initialBoxSize
        textView = tv
        addSubview(tv)
        m.textEditing = true
        styleTextView()
        window?.makeFirstResponder(tv)
        m.repaint()
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: tv
        )
    }

    @objc private func textDidChange(_ n: Notification) {
        layoutTextView()
    }

    func styleTextView() {
        guard let tv = textView, let m = model else { return }
        let style = m.textStyle
        var scaled = style
        scaled.size = style.size * zoom
        tv.font = scaled.nsFont()
        tv.textColor = m.color1.nsColor
        tv.alignment = style.align
        tv.backgroundColor = style.opaqueBackground ? m.color2.nsColor : .clear
        tv.drawsBackground = style.opaqueBackground
        layoutTextView()
    }

    private func layoutTextView() {
        guard let tv = textView, let m = model else { return }
        let origin = viewPoint(fromDoc: textOrigin)
        let text = tv.string.isEmpty ? "M" : tv.string
        let attrs = m.textStyle.attributes(color: m.color1.nsColor)
        let maxW = max(24, CGFloat(m.docWidth) - textOrigin.x)
        let requestedW = max(24, textBoxSizeDoc?.width ?? 160)
        let w = min(requestedW, maxW)
        let attr = NSAttributedString(string: text, attributes: attrs)
        let bounds = attr.boundingRect(
            with: NSSize(width: max(12, w - 8), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let baseH = max(m.textStyle.size * 1.6, bounds.height + 10)
        let requestedH = textBoxSizeDoc?.height ?? 0
        let h = max(baseH, requestedH)
        let maxH = max(20, CGFloat(m.docHeight) - textOrigin.y)
        tv.frame = CGRect(x: origin.x, y: origin.y, width: w * zoom, height: min(h, maxH) * zoom)
    }

    func hasActiveText() -> Bool { textView != nil }

    func commitActiveText() {
        guard let tv = textView, let m = model else { return }
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: tv)
        let text = tv.string
        let boxW = tv.frame.width / zoom
        tv.removeFromSuperview()
        textView = nil
        textBoxSizeDoc = nil
        m.textEditing = false
        if !text.isEmpty {
            m.rasterizeText(text, at: textOrigin, boxWidth: boxW)
        }
        m.repaint()
    }

    func cancelActiveText() {
        guard let tv = textView else { return }
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: tv)
        tv.removeFromSuperview()
        textView = nil
        textBoxSizeDoc = nil
        model?.textEditing = false
        model?.repaint()
    }

    // MARK: native Edit menu (responder chain)

    @objc func cut(_ sender: Any?) { model?.cutSelection() }
    @objc func copy(_ sender: Any?) { model?.copySelection() }
    @objc func paste(_ sender: Any?) { model?.paste() }
    @objc func delete(_ sender: Any?) { model?.deleteSelection() }
    override func selectAll(_ sender: Any?) { model?.selectAll() }

    override func responds(to aSelector: Selector!) -> Bool {
        // enable Cut/Copy/Delete only when a selection exists
        switch aSelector {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(delete(_:)):
            return model?.selection != nil
        default:
            return super.responds(to: aSelector)
        }
    }

    // MARK: transient state

    func cancelTransient() {
        var changed = false
        if curveState != nil { curveState = nil; changed = true }
        if polyPts != nil { polyPts = nil; changed = true }
        if changed { needsDisplay = true }
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let m = model, m.selection != nil else { return }
        m.liftSelection()
        if var sel = m.selection {
            sel.rect.origin.x += dx
            sel.rect.origin.y += dy
            m.selection = sel
            m.repaint()
        }
    }
}

/// NSTextView with a dashed border + Escape support.
final class PaintTextView: NSTextView {
    var onEscape: (() -> Void)?
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setupBorder()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBorder()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupBorder() {
        wantsLayer = true
        borderLayer.fillColor = nil
        borderLayer.strokeColor = CGColor(srgbRed: 0.47, green: 0.67, blue: 1, alpha: 0.9)
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [4, 3]
        layer?.addSublayer(borderLayer)
    }

    override func layout() {
        super.layout()
        borderLayer.path = CGPath(rect: bounds, transform: nil)
        borderLayer.frame = bounds
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Ruler

final class PaintRulerView: NSRulerView {
    weak var model: PaintModel?

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext,
              let m = model,
              let doc = clientView as? DocumentNSView else { return }

        g.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        g.fill(bounds)

        let zoom = m.zoom
        let step = rulerMajorStep(for: zoom)
        let minor = step / 5

        let isH = orientation == .horizontalRuler
        let originInDoc = doc.canvasOrigin
        let converted = convert(originInDoc, from: doc)
        let origin = isH ? converted.x : converted.y
        let docLen = CGFloat(isH ? m.docWidth : m.docHeight)
        let length = isH ? bounds.width : bounds.height

        g.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        g.setLineWidth(1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor(white: 0.75, alpha: 1),
        ]

        var v: CGFloat = 0
        while v <= docLen {
            let pos = (origin + v * zoom).rounded() + 0.5
            if pos >= -20 && pos <= length + 20 {
                let isMajor = v.truncatingRemainder(dividingBy: step) == 0
                let tick: CGFloat = isMajor ? 8 : 4
                g.beginPath()
                if isH {
                    g.move(to: CGPoint(x: pos, y: bounds.height))
                    g.addLine(to: CGPoint(x: pos, y: bounds.height - tick))
                } else {
                    g.move(to: CGPoint(x: bounds.width, y: pos))
                    g.addLine(to: CGPoint(x: bounds.width - tick, y: pos))
                }
                g.strokePath()
                if isMajor {
                    let s = NSAttributedString(string: "\(Int(v))", attributes: attrs)
                    NSGraphicsContext.saveGraphicsState()
                    if isH {
                        s.draw(at: NSPoint(x: pos + 2, y: 1))
                    } else {
                        let c = NSGraphicsContext.current!.cgContext
                        c.saveGState()
                        c.translateBy(x: 2, y: pos + 2)
                        c.rotate(by: .pi / 2)
                        s.draw(at: .zero)
                        c.restoreGState()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            v += minor
        }
    }

    private func rulerMajorStep(for zoom: CGFloat) -> CGFloat {
        for c in [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1000] where CGFloat(c) * zoom >= 40 {
            return CGFloat(c)
        }
        return 1000
    }
}

// MARK: - SwiftUI wrapper

struct CanvasArea: NSViewRepresentable {
    @ObservedObject var model: PaintModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0x41 / 255, green: 0x41 / 255, blue: 0x41 / 255, alpha: 1)
        scroll.scrollerStyle = .overlay
        scroll.appearance = NSAppearance(named: .darkAqua)

        let doc = DocumentNSView(model: model)
        scroll.documentView = doc

        let hRuler = PaintRulerView(scrollView: scroll, orientation: .horizontalRuler)
        hRuler.model = model
        hRuler.ruleThickness = 20
        hRuler.clientView = doc
        let vRuler = PaintRulerView(scrollView: scroll, orientation: .verticalRuler)
        vRuler.model = model
        vRuler.ruleThickness = 20
        vRuler.clientView = doc
        scroll.horizontalRulerView = hRuler
        scroll.verticalRulerView = vRuler
        scroll.rulersVisible = model.rulersOn
        scroll.hasHorizontalRuler = model.rulersOn
        scroll.hasVerticalRuler = model.rulersOn

        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak doc] _ in
            Task { @MainActor in doc?.updateDocumentFrame() }
        }
        scroll.contentView.postsFrameChangedNotifications = true
        scroll.contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll] _ in
            guard let scroll else { return }
            (scroll.horizontalRulerView as? PaintRulerView)?.needsDisplay = true
            (scroll.verticalRulerView as? PaintRulerView)?.needsDisplay = true
        }

        DispatchQueue.main.async {
            doc.updateDocumentFrame()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.hasHorizontalRuler = model.rulersOn
        scroll.hasVerticalRuler = model.rulersOn
        scroll.rulersVisible = model.rulersOn
        (scroll.horizontalRulerView as? PaintRulerView)?.needsDisplay = true
        (scroll.verticalRulerView as? PaintRulerView)?.needsDisplay = true
    }
}
