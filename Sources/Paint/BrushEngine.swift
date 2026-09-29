import AppKit

/// Freehand stroke rendering. Strokes are stamped opaquely into a temp
/// buffer, then composited onto the layer with the brush's whole-stroke
/// alpha (marker/watercolour translucency behaves like real Paint).
enum BrushEngine {

    static func stampSegment(
        ctx: CGContext, from a: CGPoint, to b: CGPoint,
        tool: Tool, brush: BrushType, size: CGFloat, color: RGB
    ) {
        if tool == .pencil {
            lineSegment(ctx, a, b, width: max(1, size), color: color)
            return
        }
        switch brush {
        case .brush:
            lineSegment(ctx, a, b, width: max(1, size), color: color)
        case .calligraphy1:
            stampAlong(a, b, spacing: 1) { p in slantStamp(ctx, p, size: size, color: color, angle: .pi / 4) }
        case .calligraphy2:
            stampAlong(a, b, spacing: 1) { p in slantStamp(ctx, p, size: size, color: color, angle: -.pi / 4) }
        case .airbrush:
            break // handled by the timer in the canvas view
        case .oil:
            oilSegment(ctx, a, b, size: size, color: color)
        case .crayon:
            stampAlong(a, b, spacing: 2) { p in crayonStamp(ctx, p, size: size, color: color) }
        case .marker:
            lineSegment(ctx, a, b, width: max(1, size * 1.4), color: color)
        case .pencil:
            stampAlong(a, b, spacing: 1.5) { p in grainStamp(ctx, p, size: max(1.5, size * 0.5), color: color) }
        case .watercolour:
            softSegment(ctx, a, b, size: size * 1.6, color: color)
        }
    }

    static func lineSegment(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat, color: RGB) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: a)
        let end = (a == b) ? CGPoint(x: b.x + 0.01, y: b.y) : b
        ctx.addLine(to: end)
        ctx.strokePath()
    }

    private static func stampAlong(_ a: CGPoint, _ b: CGPoint, spacing: CGFloat, _ stamp: (CGPoint) -> Void) {
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = max(1, hypot(dx, dy))
        let steps = Int(ceil(dist / spacing))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            stamp(CGPoint(x: a.x + dx * t, y: a.y + dy * t))
        }
    }

    private static func slantStamp(_ ctx: CGContext, _ p: CGPoint, size: CGFloat, color: RGB, angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(color.cgColor)
        let thickness = max(1, size * 0.12)
        ctx.fill(CGRect(x: -size / 2, y: -thickness / 2, width: size, height: thickness))
        ctx.restoreGState()
    }

    static func sprayAt(_ ctx: CGContext, _ p: CGPoint, size: CGFloat, color: RGB) {
        let r = max(4, size)
        ctx.setFillColor(color.cgColor)
        for _ in 0..<max(6, Int(size)) {
            let ang = CGFloat.random(in: 0..<(2 * .pi))
            let rad = sqrt(CGFloat.random(in: 0...1)) * r
            ctx.setAlpha(CGFloat.random(in: 0.5...1))
            ctx.fill(CGRect(x: p.x + cos(ang) * rad, y: p.y + sin(ang) * rad, width: 1, height: 1))
        }
        ctx.setAlpha(1)
    }

    static func spraySegment(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, size: CGFloat, color: RGB) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dist = max(1, hypot(dx, dy))
        let spacing = max(1.5, size * 0.2)
        let steps = Int(ceil(dist / spacing))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            sprayAt(ctx, CGPoint(x: a.x + dx * t, y: a.y + dy * t), size: size, color: color)
        }
    }

    private static func oilSegment(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, size: CGFloat, color: RGB) {
        lineSegment(ctx, a, b, width: max(1, size), color: color)
        ctx.saveGState()
        ctx.setAlpha(0.35)
        for offset in [-0.35, 0.28] {
            let dy = size * CGFloat(offset)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(max(1, size * 0.25))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: a.x, y: a.y + dy))
            ctx.addLine(to: CGPoint(x: b.x + 0.01, y: b.y + dy))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func crayonStamp(_ ctx: CGContext, _ p: CGPoint, size: CGFloat, color: RGB) {
        ctx.setFillColor(color.cgColor)
        for _ in 0..<max(4, Int(size * 1.5)) {
            let ang = CGFloat.random(in: 0..<(2 * .pi))
            let rad = sqrt(CGFloat.random(in: 0...1)) * size * 0.55
            ctx.setAlpha(CGFloat.random(in: 0.15...0.55))
            ctx.fill(CGRect(x: p.x + cos(ang) * rad, y: p.y + sin(ang) * rad, width: 1.4, height: 1.4))
        }
        ctx.setAlpha(1)
    }

    private static func grainStamp(_ ctx: CGContext, _ p: CGPoint, size: CGFloat, color: RGB) {
        ctx.setFillColor(color.cgColor)
        ctx.setAlpha(0.85)
        let jx = CGFloat.random(in: -0.6...0.6)
        let jy = CGFloat.random(in: -0.6...0.6)
        ctx.fillEllipse(in: CGRect(x: p.x + jx - size / 2, y: p.y + jy - size / 2, width: size, height: size))
        ctx.setAlpha(1)
    }

    private static func softSegment(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, size: CGFloat, color: RGB) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(2, size))
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: size * 0.5, color: color.cgColor)
        ctx.beginPath()
        ctx.move(to: a)
        ctx.addLine(to: CGPoint(x: b.x + 0.01, y: b.y))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
