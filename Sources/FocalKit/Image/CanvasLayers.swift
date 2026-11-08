import AppKit

/// Shows the image as GPU layer contents: no redraw while zooming or panning.
final class ImageLayerView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    /// Crisp pixels when zoomed far in (each image pixel ≥ 2 device pixels); smooth otherwise.
    var nearestNeighbour = false { didSet { if oldValue != nearestNeighbour { needsDisplay = true } } }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.magnificationFilter = nearestNeighbour ? .nearest : .linear
        layer.minificationFilter = .trilinear
    }
}

/// Draws the marks, the selection and the crop frame above the image.
final class AnnotationOverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let marks = canvas.displayedAnnotations
        if !marks.isEmpty {
            ctx.saveGState()
            let ppp = canvas.pixelsPerPoint
            let origin = canvas.canvasRect.origin
            ctx.scaleBy(x: 1 / ppp, y: 1 / ppp)
            ctx.translateBy(x: -origin.x, y: -origin.y)
            AnnotationRenderer.draw(marks, in: ctx)
            ctx.restoreGState()
        }
        let onePoint = 1 / max(canvas.magnification, 0.01)
        if let selected = canvas.selectedAnnotation { drawSelection(selected, canvas: canvas, pt: onePoint) }
        if let crop = canvas.pendingCrop { drawCrop(canvas.viewRect(crop), pixels: crop.size, pt: onePoint) }
    }

    private func drawSelection(_ a: Annotation, canvas: CanvasView, pt: CGFloat) {
        let outline = NSBezierPath(rect: canvas.viewRect(a.bounds).insetBy(dx: -3 * pt, dy: -3 * pt))
        outline.lineWidth = pt
        outline.setLineDash([4 * pt, 3 * pt], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        for h in a.handles {
            let c = canvas.viewPoint(h)
            let r = NSRect(x: c.x - 4.5 * pt, y: c.y - 4.5 * pt, width: 9 * pt, height: 9 * pt)
            let handle = NSBezierPath(ovalIn: r)
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5 * pt
            NSColor.controlAccentColor.setStroke()
            handle.stroke()
        }
    }

    private func drawCrop(_ r: NSRect, pixels: CGSize, pt: CGFloat) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: r))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()
        let border = NSBezierPath(rect: r)
        border.lineWidth = pt
        NSColor.white.setStroke()
        border.stroke()
        border.setLineDash([5 * pt, 4 * pt], count: 2, phase: 0)
        NSColor.black.setStroke()
        border.stroke()
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        let label = "\(Int(pixels.width)) × \(Int(pixels.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 * pt, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pill = NSRect(x: r.minX, y: r.maxY + 4 * pt, width: size.width + 10 * pt, height: size.height + 4 * pt)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4 * pt, yRadius: 4 * pt).fill()
        label.draw(at: NSPoint(x: pill.minX + 5 * pt, y: pill.minY + 2 * pt), withAttributes: attrs)
    }
}
