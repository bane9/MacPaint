import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Enums

enum Tool: String {
    case select, pencil, fill, text, eraser, picker, magnifier, move, brush, shape, sticker
}

enum BrushType: String, CaseIterable, Identifiable {
    case brush, calligraphy1, calligraphy2, airbrush, oil, crayon, marker, pencil, watercolour
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brush: return "Brush"
        case .calligraphy1: return "Calligraphy brush"
        case .calligraphy2: return "Calligraphy pen"
        case .airbrush: return "Airbrush"
        case .oil: return "Oil brush"
        case .crayon: return "Crayon"
        case .marker: return "Marker"
        case .pencil: return "Natural pencil"
        case .watercolour: return "Watercolour brush"
        }
    }

    /// Whole-stroke translucency (applied when the stroke buffer is composited).
    var strokeAlpha: CGFloat {
        switch self {
        case .marker: return 0.55
        case .watercolour: return 0.30
        default: return 1
        }
    }
}

enum FillPattern: String, CaseIterable, Identifiable {
    case none
    case solid
    case pct12
    case pct25
    case pct50
    case pct75
    case horizontal
    case vertical
    case cross
    case diagDown
    case diagUp
    case diagCross
    var id: String { rawValue }

    func displayName() -> String {
        switch self {
        case .none: return "No fill"
        case .solid: return "Solid color"
        case .pct12: return "12.5% halftone"
        case .pct25: return "25% halftone"
        case .pct50: return "50% halftone"
        case .pct75: return "75% halftone"
        case .horizontal: return "Horizontal hatch"
        case .vertical: return "Vertical hatch"
        case .cross: return "Cross hatch"
        case .diagDown: return "Diagonal \\"
        case .diagUp: return "Diagonal /"
        case .diagCross: return "Diagonal cross"
        }
    }
}

enum OutlineStyle: String, CaseIterable, Identifiable {
    case none
    case solid
    var id: String { rawValue }

    func displayName() -> String {
        switch self {
        case .none: return "No outline"
        case .solid: return "Solid color"
        }
    }
}

enum SelectMode { case rect, free }

// MARK: - Layer

/// One raster layer. The CGContext is flipped so all drawing uses
/// top-left-origin document coordinates (like an HTML canvas).
final class Layer: Identifiable {
    let id = UUID()
    let width: Int
    let height: Int
    let ctx: CGContext
    var visible = true
    var opacity: CGFloat = 1
    var isBackground = false

    init(w: Int, h: Int, fillWhite: Bool = false) {
        width = w
        height = h
        ctx = Layer.makeContext(w: w, h: h)
        if fillWhite {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    static func makeContext(w: Int, h: Int) -> CGContext {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: max(1, w), height: max(1, h),
            bitsPerComponent: 8, bytesPerRow: max(1, w) * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // top-left origin
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        return ctx
    }

    func image() -> CGImage? { ctx.makeImage() }
}

/// Draw a CGImage into a top-left-origin context without vertical mirroring.
func drawImageTopLeft(_ ctx: CGContext, _ img: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

// MARK: - Selection

struct Selection {
    var rect: CGRect               // doc coords
    var floating: Layer?           // lifted pixels (nil = still anchored)
    var freePath: [CGPoint]?       // free-form lasso outline (doc coords)
}

// MARK: - Text style

struct TextStyle {
    var fontName = "Helvetica"
    var size: CGFloat = 24
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var align: NSTextAlignment = .left
    var opaqueBackground = false

    func nsFont() -> NSFont {
        var font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineHeightMultiple = 1.1
        var attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont(),
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }
}

// MARK: - History snapshot

private struct Snapshot {
    let width: Int
    let height: Int
    let active: Int
    let layers: [(image: CGImage?, visible: Bool, opacity: CGFloat, isBackground: Bool)]
}

// MARK: - Model

@MainActor
final class PaintModel: ObservableObject {
    static let defaultWidth = 800
    static let defaultHeight = 512
    static let minZoom: CGFloat = 0.01
    static let maxZoom: CGFloat = 4
    static let zoomLevels: [CGFloat] = [0.01, 0.02, 0.05, 0.1, 0.125, 0.2, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    // document
    private(set) var layers: [Layer] = []
    @Published var activeLayerIndex = 0
    private(set) var docWidth = defaultWidth
    private(set) var docHeight = defaultHeight

    // tool state
    @Published var tool: Tool = .pencil
    var previousTool: Tool = .pencil
    @Published var brushType: BrushType = .brush
    @Published var shapeId: String = "rectangle"
    @Published var selectMode: SelectMode = .rect
    @Published var transparentSelection = false
    @Published var outlineStyle: OutlineStyle = .solid
    @Published var fillStyle: FillPattern = .none
    @Published var color1: RGB = .black
    @Published var color2: RGB = .white
    @Published var activeWell = 1
    @Published var customColors: [RGB] = []
    @Published var sizes: [String: CGFloat] = ["pencil": 2, "brush": 8, "eraser": 24, "shape": 3]
    @Published var textStyle = TextStyle()
    @Published var textEditing = false
    @Published var stickerChar = "😀"

    // view state
    @Published var zoom: CGFloat = 1
    @Published var gridOn = false
    @Published var rulersOn = false
    @Published var canvasRevision = 0     // bump → canvas view redraws
    @Published var docSizeRevision = 0    // bump → canvas view resizes

    // status bar
    @Published var cursorText = ""
    @Published var selectionText = ""
    @Published var fileSizeText = ""

    // selection / clipboard
    var selection: Selection? {
        didSet { selectionText = selection.map { "\(Int($0.rect.width)) × \(Int($0.rect.height))px" } ?? "" }
    }
    var internalClipboard: CGImage?
    private var clipboardChangeCount = -1

    // file
    @Published var fileName = "Untitled"
    var currentFileURL: URL?
    var dirty = false

    // history
    private var history: [Snapshot] = []
    private var histIndex = -1
    @Published var canUndo = false
    @Published var canRedo = false

    // callbacks into the canvas view
    var zoomFocusRequest: ((CGPoint?) -> Void)? // called before zoom changes with doc focus point

    init() {
        newDocument(width: PaintModel.defaultWidth, height: PaintModel.defaultHeight)
    }

    var activeLayer: Layer { layers[activeLayerIndex] }
    var docSize: CGSize { CGSize(width: docWidth, height: docHeight) }
    var sizeText: String { "\(docWidth) × \(docHeight)px" }

    func repaint() { canvasRevision &+= 1 }
    private func docChanged() {
        docSizeRevision &+= 1
        repaint()
    }

    // MARK: document lifecycle

    func newDocument(width: Int, height: Int) {
        layers = [Layer(w: width, h: height, fillWhite: true)]
        layers[0].isBackground = true
        activeLayerIndex = 0
        docWidth = width
        docHeight = height
        selection = nil
        history = []
        histIndex = -1
        pushHistory()
        dirty = false
        updateUndoFlags()
        docChanged()
        scheduleFileSize()
    }

    func newUntitled() {
        newDocument(width: PaintModel.defaultWidth, height: PaintModel.defaultHeight)
        fileName = "Untitled"
        currentFileURL = nil
        zoom = 1
    }

    // MARK: history

    private func snapshot() -> Snapshot {
        Snapshot(
            width: docWidth, height: docHeight, active: activeLayerIndex,
            layers: layers.map { ($0.image(), $0.visible, $0.opacity, $0.isBackground) }
        )
    }

    private func restore(_ s: Snapshot) {
        docWidth = s.width
        docHeight = s.height
        layers = s.layers.map { info in
            let l = Layer(w: s.width, h: s.height)
            if let img = info.image { drawImageTopLeft(l.ctx, img, in: CGRect(x: 0, y: 0, width: s.width, height: s.height)) }
            l.visible = info.visible
            l.opacity = info.opacity
            l.isBackground = info.isBackground
            return l
        }
        activeLayerIndex = min(s.active, layers.count - 1)
        selection = nil
        docChanged()
        scheduleFileSize()
    }

    private func pushHistory() {
        history.removeSubrange((histIndex + 1)...)
        history.append(snapshot())
        if history.count > 40 { history.removeFirst() }
        histIndex = history.count - 1
        dirty = true
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = histIndex > 0
        canRedo = histIndex < history.count - 1
    }

    /// Finish a mutation: redraw + snapshot.
    func commit() {
        pushHistory()
        repaint()
        scheduleFileSize()
    }

    func undo() {
        // a floating selection is an uncommitted edit: the first undo cancels
        // the lift itself, restoring the current committed state
        if let sel = selection, sel.floating != nil {
            selection = nil
            restore(history[histIndex])
            updateUndoFlags()
            return
        }
        guard canUndo else { return }
        selection = nil
        histIndex -= 1
        restore(history[histIndex])
        dirty = true
        updateUndoFlags()
    }

    func redo() {
        guard canRedo else { return }
        histIndex += 1
        restore(history[histIndex])
        dirty = true
        updateUndoFlags()
    }

    // MARK: layers

    func setActiveLayer(_ i: Int) {
        guard layers.indices.contains(i), i != activeLayerIndex else { return }
        dropSelection() // floating pixels belong to the layer they came from
        activeLayerIndex = i
        repaint()
    }

    func addLayer() {
        dropSelection(commit: false)
        let l = Layer(w: docWidth, h: docHeight)
        layers.insert(l, at: activeLayerIndex + 1)
        activeLayerIndex += 1
        commit()
    }

    func deleteLayer(_ i: Int) {
        guard layers.count > 1, layers.indices.contains(i) else { return }
        dropSelection(commit: false)
        layers.remove(at: i)
        if activeLayerIndex > i {
            activeLayerIndex -= 1
        } else {
            activeLayerIndex = min(activeLayerIndex, layers.count - 1)
        }
        commit()
    }

    func duplicateLayer(_ i: Int) {
        guard layers.indices.contains(i) else { return }
        dropSelection(commit: false)
        let src = layers[i]
        let copy = Layer(w: docWidth, h: docHeight)
        if let img = src.image() {
            drawImageTopLeft(copy.ctx, img, in: CGRect(x: 0, y: 0, width: docWidth, height: docHeight))
        }
        copy.visible = src.visible
        copy.opacity = src.opacity
        layers.insert(copy, at: i + 1)
        activeLayerIndex = i + 1
        commit()
    }

    func mergeDown(_ i: Int) {
        guard i > 0, layers.indices.contains(i) else { return }
        dropSelection(commit: false)
        let upper = layers[i]
        let lower = layers[i - 1]
        if upper.visible, let img = upper.image() {
            lower.ctx.saveGState()
            lower.ctx.setAlpha(upper.opacity)
            lower.ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawImageTopLeft(lower.ctx, img, in: CGRect(x: 0, y: 0, width: docWidth, height: docHeight))
            lower.ctx.endTransparencyLayer()
            lower.ctx.restoreGState()
        }
        layers.remove(at: i)
        if activeLayerIndex >= i {
            activeLayerIndex = max(0, activeLayerIndex - 1)
        }
        commit()
    }

    func moveLayer(_ i: Int, dir: Int) {
        let j = i + dir
        guard layers.indices.contains(i), layers.indices.contains(j) else { return }
        dropSelection(commit: false)
        layers.swapAt(i, j)
        if activeLayerIndex == i { activeLayerIndex = j } else if activeLayerIndex == j { activeLayerIndex = i }
        commit()
    }

    func setLayerVisible(_ i: Int, _ v: Bool) {
        guard layers.indices.contains(i) else { return }
        layers[i].visible = v
        commit()
    }

    func setActiveLayerOpacity(_ o: CGFloat, commitNow: Bool) {
        activeLayer.opacity = o
        if commitNow { commit() } else { repaint() }
    }

    // MARK: colors

    var activeColor: RGB { activeWell == 1 ? color1 : color2 }

    func setColor(well: Int, _ c: RGB) {
        if well == 1 { color1 = c } else { color2 = c }
    }

    func addCustomColor(_ c: RGB) {
        if !customColors.contains(c) {
            customColors.append(c)
            if customColors.count > 10 { customColors.removeFirst() }
        }
        setColor(well: activeWell, c)
    }

    // MARK: tool switching

    func setTool(_ t: Tool) {
        guard tool != t else { return }
        if selection != nil && t != .select && t != .magnifier && t != .picker && t != .move {
            dropSelection(commit: true)
        }
        previousTool = tool
        tool = t
        repaint()
    }

    func sizeKey(for tool: Tool) -> String? {
        switch tool {
        case .pencil: return "pencil"
        case .brush: return "brush"
        case .eraser: return "eraser"
        case .shape: return "shape"
        default: return nil
        }
    }

    var currentSizeKey: String? { sizeKey(for: tool) }

    var currentSize: CGFloat {
        get { currentSizeKey.flatMap { sizes[$0] } ?? 8 }
        set { if let k = currentSizeKey { sizes[k] = newValue } }
    }

    // MARK: zoom

    func setZoom(_ z: CGFloat, focusDocPoint: CGPoint? = nil) {
        let clamped = min(Self.maxZoom, max(Self.minZoom, z))
        guard clamped != zoom else { return }
        zoomFocusRequest?(focusDocPoint)
        zoom = clamped
        docSizeRevision &+= 1
    }

    func zoomStep(_ dir: Int, focusDocPoint: CGPoint? = nil) {
        let idx = nearestZoomIndex()
        let ni = min(PaintModel.zoomLevels.count - 1, max(0, idx + dir))
        setZoom(PaintModel.zoomLevels[ni], focusDocPoint: focusDocPoint)
    }

    func nearestZoomIndex() -> Int {
        var best = 0
        var bd = CGFloat.greatestFiniteMagnitude
        for (i, z) in PaintModel.zoomLevels.enumerated() where abs(z - zoom) < bd {
            bd = abs(z - zoom)
            best = i
        }
        return best
    }

    var zoomText: String {
        let pct = zoom * 100
        return pct.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(pct))%" : String(format: "%.1f%%", pct)
    }

    // MARK: composite

    func compositeImage(overWhite: Bool = false) -> CGImage? {
        let ctx = Layer.makeContext(w: docWidth, h: docHeight)
        if overWhite {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: docWidth, height: docHeight))
        }
        for layer in layers where layer.visible {
            guard let img = layer.image() else { continue }
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: docWidth, height: docHeight))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    // MARK: pixel operations

    func pickColor(at p: CGPoint) -> RGB? {
        // sample over white so semi-transparent pixels pick their visible color
        // (a premultiplied read would return darkened components)
        guard let img = compositeImage(overWhite: true) else { return nil }
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < docWidth, y < docHeight else { return nil }
        let ctx = Layer.makeContext(w: 1, h: 1)
        drawImageTopLeft(ctx, img, in: CGRect(x: CGFloat(-x), y: CGFloat(-y), width: CGFloat(docWidth), height: CGFloat(docHeight)))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGB(px[0], px[1], px[2])
    }

    func floodFill(at p: CGPoint, color: RGB) {
        let w = docWidth, h = docHeight
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let ctx = activeLayer.ctx
        guard let raw = ctx.data else { return }
        let bpr = ctx.bytesPerRow
        let d = raw.bindMemory(to: UInt8.self, capacity: bpr * h)

        let start = y * bpr + x * 4
        let sr = d[start], sg = d[start + 1], sb = d[start + 2], sa = d[start + 3]
        let fr = color.r, fg = color.g, fb = color.b
        if sr == fr && sg == fg && sb == fb && sa == 255 { return }

        @inline(__always) func matches(_ i: Int) -> Bool {
            d[i] == sr && d[i + 1] == sg && d[i + 2] == sb && d[i + 3] == sa
        }
        @inline(__always) func paint(_ i: Int) {
            d[i] = fr; d[i + 1] = fg; d[i + 2] = fb; d[i + 3] = 255
        }

        var stack: [(Int, Int)] = [(x, y)]
        while let (cx, cy) = stack.popLast() {
            var i = cy * bpr + cx * 4
            if !matches(i) { continue }
            var lx = cx
            while lx > 0 && matches(cy * bpr + (lx - 1) * 4) { lx -= 1 }
            var rx = cx
            while rx < w - 1 && matches(cy * bpr + (rx + 1) * 4) { rx += 1 }
            var spanUp = false, spanDown = false
            for px in lx...rx {
                i = cy * bpr + px * 4
                paint(i)
                if cy > 0 {
                    let up = matches((cy - 1) * bpr + px * 4)
                    if up && !spanUp { stack.append((px, cy - 1)); spanUp = true }
                    if !up { spanUp = false }
                }
                if cy < h - 1 {
                    let dn = matches((cy + 1) * bpr + px * 4)
                    if dn && !spanDown { stack.append((px, cy + 1)); spanDown = true }
                    if !dn { spanDown = false }
                }
            }
        }
        commit()
    }

    /// Fill an area behind removed pixels: background color on the base layer, transparent elsewhere.
    func clearRegion(_ layer: Layer, rect: CGRect, clipPath: CGPath? = nil) {
        let ctx = layer.ctx
        ctx.saveGState()
        if let p = clipPath {
            ctx.addPath(p)
            ctx.clip()
        }
        if layer.isBackground {
            ctx.setFillColor(color2.cgColor)
            ctx.fill(rect)
        } else {
            ctx.clear(rect)
        }
        ctx.restoreGState()
    }

    // MARK: selection

    func setSelection(_ sel: Selection?) {
        selection = sel
        repaint()
    }

    func liftSelection() {
        guard var sel = selection, sel.floating == nil else { return }
        let r = sel.rect.integral
        let buf = Layer(w: max(1, Int(r.width)), h: max(1, Int(r.height)))
        guard let srcImg = activeLayer.image() else { return }

        if let pathPts = sel.freePath {
            let path = CGMutablePath()
            path.addLines(between: pathPts)
            path.closeSubpath()
            buf.ctx.saveGState()
            let shifted = CGMutablePath()
            shifted.addPath(path, transform: CGAffineTransform(translationX: -r.origin.x, y: -r.origin.y))
            buf.ctx.addPath(shifted)
            buf.ctx.clip()
            drawImageTopLeft(buf.ctx, srcImg, in: CGRect(x: -r.origin.x, y: -r.origin.y, width: CGFloat(docWidth), height: CGFloat(docHeight)))
            buf.ctx.restoreGState()
            clearRegion(activeLayer, rect: CGRect(x: 0, y: 0, width: docWidth, height: docHeight), clipPath: path)
        } else {
            drawImageTopLeft(buf.ctx, srcImg, in: CGRect(x: -r.origin.x, y: -r.origin.y, width: CGFloat(docWidth), height: CGFloat(docHeight)))
            clearRegion(activeLayer, rect: r)
        }

        if transparentSelection {
            makeColorTransparent(buf, color: color2)
        }
        sel.floating = buf
        selection = sel
        repaint()
    }

    private func makeColorTransparent(_ layer: Layer, color: RGB) {
        guard let raw = layer.ctx.data else { return }
        let bpr = layer.ctx.bytesPerRow
        let d = raw.bindMemory(to: UInt8.self, capacity: bpr * layer.height)
        for y in 0..<layer.height {
            for x in 0..<layer.width {
                let i = y * bpr + x * 4
                if abs(Int(d[i]) - Int(color.r)) < 12,
                   abs(Int(d[i + 1]) - Int(color.g)) < 12,
                   abs(Int(d[i + 2]) - Int(color.b)) < 12 {
                    d[i] = 0; d[i + 1] = 0; d[i + 2] = 0; d[i + 3] = 0
                }
            }
        }
    }

    func dropSelection(commit shouldCommit: Bool = true) {
        guard let sel = selection else { return }
        if let floating = sel.floating, let img = floating.image() {
            drawImageTopLeft(activeLayer.ctx, img, in: sel.rect)
            selection = nil
            if shouldCommit { commit() } else { repaint() }
        } else {
            selection = nil
            repaint()
        }
    }

    func deleteSelection() {
        guard let sel = selection else { return }
        if sel.floating != nil {
            selection = nil
            commit()
        } else {
            if let pathPts = sel.freePath {
                let path = CGMutablePath()
                path.addLines(between: pathPts)
                path.closeSubpath()
                clearRegion(activeLayer, rect: CGRect(x: 0, y: 0, width: docWidth, height: docHeight), clipPath: path)
            } else {
                clearRegion(activeLayer, rect: sel.rect.integral)
            }
            selection = nil
            commit()
        }
    }

    func selectAll() {
        dropSelection()
        setTool(.select)
        setSelection(Selection(rect: CGRect(x: 0, y: 0, width: docWidth, height: docHeight), floating: nil, freePath: nil))
    }

    func selectionAsImage() -> CGImage? {
        guard let sel = selection else { return nil }
        if let floating = sel.floating {
            // the floating buffer keeps its lift-time size; honor any scaling
            let w = max(1, Int(sel.rect.width.rounded()))
            let h = max(1, Int(sel.rect.height.rounded()))
            if w == floating.width && h == floating.height {
                return floating.image()
            }
            let scaled = Layer(w: w, h: h)
            if let img = floating.image() {
                drawImageTopLeft(scaled.ctx, img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return scaled.image()
        }
        let r = sel.rect.integral
        let buf = Layer(w: max(1, Int(r.width)), h: max(1, Int(r.height)))
        guard let srcImg = activeLayer.image() else { return nil }
        if let pathPts = sel.freePath {
            let shifted = CGMutablePath()
            let path = CGMutablePath()
            path.addLines(between: pathPts)
            path.closeSubpath()
            shifted.addPath(path, transform: CGAffineTransform(translationX: -r.origin.x, y: -r.origin.y))
            buf.ctx.saveGState()
            buf.ctx.addPath(shifted)
            buf.ctx.clip()
        }
        drawImageTopLeft(buf.ctx, srcImg, in: CGRect(x: -r.origin.x, y: -r.origin.y, width: CGFloat(docWidth), height: CGFloat(docHeight)))
        if sel.freePath != nil { buf.ctx.restoreGState() }
        return buf.image()
    }

    // MARK: clipboard

    func copySelection() {
        guard let img = selectionAsImage() else { return }
        internalClipboard = img
        let rep = NSBitmapImageRep(cgImage: img)
        if let png = rep.representation(using: .png, properties: [:]) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(png, forType: .png)
            clipboardChangeCount = pb.changeCount
        }
    }

    func cutSelection() {
        guard selection != nil else { return }
        copySelection()
        deleteSelection()
    }

    func paste() {
        var image: CGImage?
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: data) {
            image = rep.cgImage
        }
        // fall back to the internal buffer only if the pasteboard still holds
        // our own copy (someone else's text copy must not paste a stale image)
        if image == nil && pb.changeCount == clipboardChangeCount {
            image = internalClipboard
        }
        guard let img = image else { return }
        pasteImage(img)
    }

    func pasteImage(_ img: CGImage) {
        dropSelection()
        let w = img.width, h = img.height
        if w > docWidth || h > docHeight {
            resizeCanvas(width: max(w, docWidth), height: max(h, docHeight), stretch: false, commitNow: false)
        }
        let buf = Layer(w: w, h: h)
        drawImageTopLeft(buf.ctx, img, in: CGRect(x: 0, y: 0, width: w, height: h))
        setTool(.select)
        setSelection(Selection(rect: CGRect(x: 0, y: 0, width: w, height: h), floating: buf, freePath: nil))
    }

    // MARK: transforms

    private func transformAllLayers(newW: Int, newH: Int, _ draw: (CGContext, Layer, CGImage?) -> Void) {
        var newLayers: [Layer] = []
        for layer in layers {
            let nl = Layer(w: newW, h: newH)
            nl.visible = layer.visible
            nl.opacity = layer.opacity
            nl.isBackground = layer.isBackground
            draw(nl.ctx, layer, layer.image())
            newLayers.append(nl)
        }
        layers = newLayers
        docWidth = newW
        docHeight = newH
        docChanged()
    }

    func rotate(_ degrees: Int) {
        dropSelection()
        let w = docWidth, h = docHeight
        if degrees == 180 {
            transformAllLayers(newW: w, newH: h) { ctx, _, img in
                guard let img else { return }
                ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
                ctx.rotate(by: .pi)
                drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        } else {
            let cw = degrees > 0
            transformAllLayers(newW: h, newH: w) { ctx, _, img in
                guard let img else { return }
                if cw {
                    ctx.translateBy(x: CGFloat(h), y: 0)
                    ctx.rotate(by: .pi / 2)
                } else {
                    ctx.translateBy(x: 0, y: CGFloat(w))
                    ctx.rotate(by: -.pi / 2)
                }
                drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        commit()
    }

    func flip(horizontal: Bool) {
        dropSelection()
        let w = docWidth, h = docHeight
        transformAllLayers(newW: w, newH: h) { ctx, _, img in
            guard let img else { return }
            if horizontal {
                ctx.translateBy(x: CGFloat(w), y: 0)
                ctx.scaleBy(x: -1, y: 1)
            } else {
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
            }
            drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        commit()
    }

    static let maxCanvasDimension = 10000

    func resizeCanvas(width newW: Int, height newH: Int, stretch: Bool, commitNow: Bool = true) {
        let w = docWidth, h = docHeight
        let newW = min(PaintModel.maxCanvasDimension, max(1, newW))
        let newH = min(PaintModel.maxCanvasDimension, max(1, newH))
        dropSelection()
        transformAllLayers(newW: max(1, newW), newH: max(1, newH)) { ctx, layer, img in
            if layer.isBackground {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
            }
            guard let img else { return }
            if stretch {
                drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            } else {
                drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        if commitNow { commit() }
    }

    func skew(hDeg: CGFloat, vDeg: CGFloat) {
        dropSelection()
        let w = CGFloat(docWidth), h = CGFloat(docHeight)
        let tanH = tan(min(89, max(-89, hDeg)) * .pi / 180)
        let tanV = tan(min(89, max(-89, vDeg)) * .pi / 180)
        let cap = CGFloat(PaintModel.maxCanvasDimension)
        let newW = Int(min(cap, max(1, (w + abs(tanH) * h).rounded())))
        let newH = Int(min(cap, max(1, (h + abs(tanV) * CGFloat(newW)).rounded())))
        transformAllLayers(newW: newW, newH: newH) { ctx, layer, img in
            if layer.isBackground {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
            }
            guard let img else { return }
            let t = CGAffineTransform(a: 1, b: tanV, c: tanH, d: 1,
                                      tx: tanH < 0 ? abs(tanH) * h : 0,
                                      ty: tanV < 0 ? abs(tanV) * CGFloat(newW) : 0)
            ctx.concatenate(t)
            drawImageTopLeft(ctx, img, in: CGRect(x: 0, y: 0, width: Int(w), height: Int(h)))
        }
        commit()
    }

    func cropToSelection() {
        guard let sel = selection else { return }
        if sel.floating != nil { dropSelection(commit: false) }
        let r = sel.rect.integral.intersection(CGRect(x: 0, y: 0, width: docWidth, height: docHeight))
        guard r.width >= 1, r.height >= 1 else { return }
        selection = nil
        transformAllLayers(newW: Int(r.width), newH: Int(r.height)) { ctx, _, img in
            guard let img else { return }
            drawImageTopLeft(ctx, img, in: CGRect(x: -r.origin.x, y: -r.origin.y, width: CGFloat(docWidth), height: CGFloat(docHeight)))
        }
        commit()
    }

    // MARK: text commit

    func rasterizeText(_ string: String, at origin: CGPoint, boxWidth: CGFloat) {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let ctx = activeLayer.ctx
        let attrs = textStyle.attributes(color: color1.nsColor)
        let attr = NSAttributedString(string: string, attributes: attrs)
        let bounds = attr.boundingRect(
            with: NSSize(width: boxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        ctx.saveGState()
        if textStyle.opaqueBackground {
            ctx.setFillColor(color2.cgColor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: boxWidth, height: bounds.height + 4))
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attr.draw(with: NSRect(x: origin.x + 2, y: origin.y + 2, width: boxWidth, height: bounds.height + 4),
                  options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        commit()
    }

    func stampSticker(at p: CGPoint) {
        let ctx = activeLayer.ctx
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64)]
        let attr = NSAttributedString(string: stickerChar, attributes: attrs)
        let size = attr.size()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attr.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        commit()
    }

    // MARK: file size estimate

    private var fileSizeTask: Task<Void, Never>?

    func scheduleFileSize() {
        fileSizeTask?.cancel()
        fileSizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let img = self.compositeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: img)
            if let png = rep.representation(using: .png, properties: [:]) {
                self.fileSizeText = "Size: " + Self.formatBytes(png.count)
            }
        }
    }

    static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / 1024 / 1024)
    }

    // MARK: file I/O

    func canOpenImage(from url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    }

    func openImage(from url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let probe = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        // decode with the EXIF orientation applied (portrait photos etc.)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(probe.width, probe.height),
        ]
        let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? probe
        newDocument(width: img.width, height: img.height)
        drawImageTopLeft(layers[0].ctx, img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        commit()
        dirty = false
        fileName = url.deletingPathExtension().lastPathComponent
        currentFileURL = url
        addRecent(url)
        repaint()
    }

    func save(to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let overWhite = ["jpg", "jpeg", "bmp", "gif"].contains(ext)
        guard let img = compositeImage(overWhite: overWhite) else { return false }
        let type: UTType = {
            switch ext {
            case "jpg", "jpeg": return .jpeg
            case "bmp": return .bmp
            case "gif": return .gif
            case "tif", "tiff": return .tiff
            case "heic": return .heic
            case "webp": return .webP
            default: return .png
            }
        }()
        // if this format can't be encoded on this system, fail so the caller
        // can fall back to Save As instead of writing wrong bytes
        let encodable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard encodable.contains(type.identifier),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        let props: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        dirty = false
        fileName = url.deletingPathExtension().lastPathComponent
        currentFileURL = url
        addRecent(url)
        return true
    }

    // MARK: recents

    func recentFiles() -> [URL] {
        (UserDefaults.standard.array(forKey: "recents") as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addRecent(_ url: URL) {
        var paths = UserDefaults.standard.array(forKey: "recents") as? [String] ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(5)), forKey: "recents")
    }
}
