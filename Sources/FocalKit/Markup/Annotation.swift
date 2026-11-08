import AppKit

public struct RGBAColor: Hashable, Sendable, Codable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    public func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(red, green, blue, a) }

    public static let red = RGBAColor(1, 0.231, 0.188)
    public static let black = RGBAColor(0, 0, 0)
    public static let white = RGBAColor(1, 1, 1)
    public static let palette: [(name: String, color: RGBAColor)] = [
        ("Red", .red), ("Orange", RGBAColor(1, 0.584, 0)), ("Yellow", RGBAColor(1, 0.8, 0)),
        ("Green", RGBAColor(0.204, 0.78, 0.349)), ("Blue", RGBAColor(0, 0.478, 1)),
        ("Purple", RGBAColor(0.686, 0.322, 0.871)), ("Black", .black), ("White", .white),
    ]
}

public enum AnnotationKind: String, Sendable, CaseIterable {
    case pen, highlighter, line, arrow, rectangle, ellipse, text, counter, redact

    public var label: String {
        switch self {
        case .pen: "Drawing"
        case .highlighter: "Highlight"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Oval"
        case .text: "Text"
        case .counter: "Number"
        case .redact: "Redaction"
        }
    }
}

/// One mark on an image. All geometry is in image pixels, top-left origin, so marks survive
/// zooming, cropping (the crop is just a window onto these coordinates) and rotation.
public struct Annotation: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    /// pen/highlighter: the stroke; line/arrow: start, end; rectangle/ellipse/redact: two corners;
    /// text: top-left of the text; counter: center of the badge.
    public var points: [CGPoint]
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var text: String
    public var fontSize: CGFloat
    public var number: Int

    public init(kind: AnnotationKind, points: [CGPoint], color: RGBAColor, lineWidth: CGFloat,
                text: String = "", fontSize: CGFloat = 24, number: Int = 0, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.fontSize = fontSize
        self.number = number
    }
}

extension Annotation {
    public var rect: CGRect {
        guard points.count >= 2 else { return CGRect(origin: points.first ?? .zero, size: .zero) }
        return Geometry.rect(points[0], points[1])
    }

    public static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    public var textAttributes: [NSAttributedString.Key: Any] {
        [.font: Self.font(size: fontSize), .foregroundColor: color.nsColor]
    }

    public var textSize: CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        let r = s.boundingRect(with: CGSize(width: 1e7, height: 1e7), options: [.usesLineFragmentOrigin],
                               attributes: textAttributes)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    public var counterDiameter: CGFloat { fontSize * 1.6 }
    public var arrowHeadLength: CGFloat { max(lineWidth * 4, 10) }

    /// Area the mark paints, for hit testing and selection outlines.
    public var bounds: CGRect {
        let pad = lineWidth / 2 + 1
        switch kind {
        case .pen, .highlighter, .line:
            return Geometry.boundingBox(points).insetBy(dx: -pad, dy: -pad)
        case .arrow:
            let head = arrowHeadLength
            return Geometry.boundingBox(points).insetBy(dx: -(head + pad), dy: -(head + pad))
        case .rectangle, .ellipse:
            return rect.insetBy(dx: -pad, dy: -pad)
        case .redact:
            return rect
        case .text:
            return CGRect(origin: points.first ?? .zero, size: textSize)
        case .counter:
            let c = points.first ?? .zero, d = counterDiameter
            return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        }
    }

    public func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch kind {
        case .pen, .highlighter, .line:
            return Geometry.distance(p, toPolyline: points) <= lineWidth / 2 + t
        case .arrow:
            guard points.count >= 2 else { return false }
            return Geometry.distance(p, toPolyline: points) <= lineWidth / 2 + t
                || hypot(p.x - points[1].x, p.y - points[1].y) <= arrowHeadLength + t
        case .rectangle:
            return Geometry.distance(p, toRectEdge: rect) <= lineWidth / 2 + t
        case .ellipse:
            let r = rect
            let rx = r.width / 2, ry = r.height / 2
            guard rx > 0, ry > 0 else { return false }
            let dx = (p.x - r.midX) / rx, dy = (p.y - r.midY) / ry
            return abs(sqrt(dx * dx + dy * dy) - 1) * min(rx, ry) <= lineWidth / 2 + t
        case .redact, .text, .counter:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    /// Drag handles: endpoints for lines and arrows, corners for boxes.
    public var handles: [CGPoint] {
        switch kind {
        case .line, .arrow:
            return points.count >= 2 ? [points[0], points[1]] : []
        case .rectangle, .ellipse, .redact:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .pen, .highlighter, .text, .counter:
            return []
        }
    }

    public func movingHandle(_ index: Int, to p: CGPoint) -> Annotation {
        var a = self
        switch kind {
        case .line, .arrow:
            a.points[index] = p
        case .rectangle, .ellipse, .redact:
            let h = handles
            a.points = [h[(index + 2) % 4], p]
        case .pen, .highlighter, .text, .counter:
            break
        }
        return a
    }

    /// The fixed point a handle drag pivots around (for shift-constraining).
    public func anchor(forHandle index: Int) -> CGPoint? {
        switch kind {
        case .line, .arrow: return points[1 - index]
        case .rectangle, .ellipse, .redact: return handles[(index + 2) % 4]
        default: return nil
        }
    }

    public func translated(by d: CGVector) -> Annotation {
        var a = self
        a.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return a
    }

    /// Rotate with the image (90°). Text keeps reading horizontally, so its center moves, not its corner.
    public func rotated(clockwise: Bool, imageSize: CGSize) -> Annotation {
        var a = self
        if kind == .text, let origin = points.first {
            let size = textSize
            let c = Geometry.rotate(CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2),
                                    clockwise: clockwise, imageSize: imageSize)
            a.points = [CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)]
        } else {
            a.points = points.map { Geometry.rotate($0, clockwise: clockwise, imageSize: imageSize) }
        }
        return a
    }
}

public enum Geometry {
    public static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 90° rotation of a point in a top-left-origin image of `imageSize`.
    public static func rotate(_ p: CGPoint, clockwise: Bool, imageSize s: CGSize) -> CGPoint {
        clockwise ? CGPoint(x: s.height - p.y, y: p.x) : CGPoint(x: p.y, y: s.width - p.x)
    }

    public static func rotate(_ r: CGRect, clockwise: Bool, imageSize s: CGSize) -> CGRect {
        rect(rotate(CGPoint(x: r.minX, y: r.minY), clockwise: clockwise, imageSize: s),
             rotate(CGPoint(x: r.maxX, y: r.maxY), clockwise: clockwise, imageSize: s))
    }

    public static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    public static func distance(_ p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 1..<pts.count { best = min(best, distance(p, toSegment: pts[i - 1], pts[i])) }
        return best
    }

    public static func distance(_ p: CGPoint, toRectEdge r: CGRect) -> CGFloat {
        if r.contains(p) {
            return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Snap a drag to the nearest 45° direction.
    public static func constrain45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + len * cos(angle), y: a.y + len * sin(angle))
    }

    /// Make a box drag square.
    public static func constrainSquare(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }
}
