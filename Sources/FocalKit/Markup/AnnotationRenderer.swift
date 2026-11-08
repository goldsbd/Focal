import AppKit

/// Draws annotations. One code path for the screen and for saved files, so what you see is what you save.
/// The context must be in image-pixel space with a top-left origin, and `NSGraphicsContext.current`
/// must wrap it as flipped (text is drawn through AppKit).
public enum AnnotationRenderer {
    public static let highlighterAlpha = 0.38

    public static func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for a in annotations { draw(a, in: ctx) }
    }

    public static func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(a.lineWidth)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)

        switch a.kind {
        case .pen:
            strokeFreehand(a.points, width: a.lineWidth, in: ctx)
        case .highlighter:
            let c = a.color.withAlpha(highlighterAlpha).cgColor
            ctx.setStrokeColor(c)
            ctx.setFillColor(c)
            strokeFreehand(a.points, width: a.lineWidth, in: ctx)
        case .line:
            guard a.points.count >= 2 else { return }
            ctx.move(to: a.points[0])
            ctx.addLine(to: a.points[1])
            ctx.strokePath()
        case .arrow:
            guard a.points.count >= 2 else { return }
            drawArrow(from: a.points[0], to: a.points[1], width: a.lineWidth, head: a.arrowHeadLength, in: ctx)
        case .rectangle:
            ctx.setLineJoin(.miter)
            ctx.stroke(a.rect)
        case .ellipse:
            ctx.strokeEllipse(in: a.rect)
        case .redact:
            ctx.fill(a.rect)
        case .text:
            guard let origin = a.points.first, !a.text.isEmpty else { return }
            (a.text as NSString).draw(in: CGRect(origin: origin, size: a.textSize), withAttributes: a.textAttributes)
        case .counter:
            guard let c = a.points.first else { return }
            let d = a.counterDiameter
            ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            let label = "\(a.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
                .foregroundColor: a.color.luminance > 0.6 ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        }
    }

    static func strokeFreehand(_ pts: [CGPoint], width: CGFloat, in ctx: CGContext) {
        guard let first = pts.first else { return }
        if pts.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            return
        }
        ctx.addPath(smoothPath(pts))
        ctx.strokePath()
    }

    /// Quadratic curves through segment midpoints: smooth, and passes near every sample.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 3 else {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func drawArrow(from a: CGPoint, to b: CGPoint, width: CGFloat, head headLength: CGFloat, in ctx: CGContext) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let head = min(headLength, len * 0.6)
        let half = head * 0.5
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        // The shaft stops inside the head so its round cap never pokes past the tip.
        let shaftEnd = CGPoint(x: b.x - ux * head * 0.6, y: b.y - uy * head * 0.6)
        ctx.move(to: a)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.fillPath()
    }
}
