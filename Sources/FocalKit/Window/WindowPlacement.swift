import CoreGraphics

/// A display as AppKit reports it (global coordinates, origin bottom-left of the main display).
public struct ScreenGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum PlacementPolicy: String, CaseIterable, Sendable {
    /// The display with the menu bar, as chosen in System Settings → Displays.
    case centerOnMainDisplay
    case centerOnPointerDisplay
    case rememberLastPosition

    public var title: String {
        switch self {
        case .centerOnMainDisplay: "Center of the main display"
        case .centerOnPointerDisplay: "Center of the display with the pointer"
        case .rememberLastPosition: "Where I last left a window"
        }
    }
}

public struct PlacementRequest: Sendable {
    /// Size of the media at 100 %, in points.
    public var mediaSize: CGSize
    /// Title bar + toolbar (+ any accessory bar) height that sits above the content.
    public var chromeHeight: CGFloat
    public var policy: PlacementPolicy
    /// `screens[0]` must be the main display (the one with the menu bar).
    public var screens: [ScreenGeometry]
    public var pointer: CGPoint
    public var lastFrame: CGRect?
    /// Largest share of the display's visible area a new window may take (0.1…1).
    public var fitFraction: CGFloat
    public var allowUpscale: Bool
    public var minContentSize: CGSize
    /// Pictures shrink as a whole (keep their shape); text caps width and height independently.
    public var preserveAspect: Bool

    public init(mediaSize: CGSize, chromeHeight: CGFloat, policy: PlacementPolicy, screens: [ScreenGeometry],
                pointer: CGPoint, lastFrame: CGRect?, fitFraction: CGFloat, allowUpscale: Bool, minContentSize: CGSize,
                preserveAspect: Bool = true) {
        self.mediaSize = mediaSize
        self.chromeHeight = chromeHeight
        self.policy = policy
        self.screens = screens
        self.pointer = pointer
        self.lastFrame = lastFrame
        self.fitFraction = fitFraction
        self.allowUpscale = allowUpscale
        self.minContentSize = minContentSize
        self.preserveAspect = preserveAspect
    }
}

public struct Placement: Equatable, Sendable {
    public var frame: CGRect
    public var contentRect: CGRect
}

/// Pure window-geometry rules. The content (the image or video) is what gets centered,
/// not the frame including the title bar, so the picture's center is the display's center.
public enum WindowPlacement {
    public static func place(_ r: PlacementRequest) -> Placement {
        guard let main = r.screens.first else {
            let size = CGSize(width: max(r.mediaSize.width, r.minContentSize.width),
                              height: max(r.mediaSize.height, r.minContentSize.height))
            return frameAround(content: CGRect(origin: .zero, size: size), chrome: r.chromeHeight)
        }

        if r.policy == .rememberLastPosition, let last = r.lastFrame,
           let screen = screen(showing: last, in: r.screens) {
            let frame = clamp(last, into: screen.visibleFrame)
            return Placement(frame: frame, contentRect: contentRect(forFrame: frame, chrome: r.chromeHeight))
        }

        let screen: ScreenGeometry
        switch r.policy {
        case .centerOnPointerDisplay:
            screen = r.screens.first { $0.frame.contains(r.pointer) } ?? main
        case .centerOnMainDisplay, .rememberLastPosition:
            screen = main
        }
        let area = screen.visibleFrame
        let size = fittedContentSize(media: r.mediaSize, chrome: r.chromeHeight, area: area,
                                     fitFraction: r.fitFraction, allowUpscale: r.allowUpscale,
                                     minContent: r.minContentSize, preserveAspect: r.preserveAspect)
        return centered(contentSize: size, chrome: r.chromeHeight, at: CGPoint(x: area.midX, y: area.midY), in: area)
    }

    /// Re-fit a window for new media (next file, rotation) keeping its content centered where it is now.
    public static func refit(mediaSize: CGSize, chrome: CGFloat, keepingCenter center: CGPoint, in area: CGRect,
                             fitFraction: CGFloat, allowUpscale: Bool, minContent: CGSize,
                             preserveAspect: Bool = true) -> Placement {
        let size = fittedContentSize(media: mediaSize, chrome: chrome, area: area, fitFraction: fitFraction,
                                     allowUpscale: allowUpscale, minContent: minContent, preserveAspect: preserveAspect)
        return centered(contentSize: size, chrome: chrome, at: center, in: area)
    }

    public static func fittedContentSize(media: CGSize, chrome: CGFloat, area: CGRect, fitFraction: CGFloat,
                                         allowUpscale: Bool, minContent: CGSize, preserveAspect: Bool = true) -> CGSize {
        let fraction = min(max(fitFraction, 0.1), 1)
        let maxWidth = area.width * fraction
        let maxHeight = area.height * fraction - chrome
        guard media.width > 0, media.height > 0, maxWidth > 0, maxHeight > 0 else { return minContent }
        let width: CGFloat, height: CGFloat
        if preserveAspect {
            var scale = min(maxWidth / media.width, maxHeight / media.height)
            if !allowUpscale { scale = min(scale, 1) }
            width = (media.width * scale).rounded()
            height = (media.height * scale).rounded()
        } else {
            width = min(media.width, maxWidth).rounded()
            height = min(media.height, maxHeight).rounded()
        }
        return CGSize(width: min(max(width, minContent.width), area.width),
                      height: min(max(height, minContent.height), max(area.height - chrome, minContent.height)))
    }

    public static func centered(contentSize: CGSize, chrome: CGFloat, at center: CGPoint, in area: CGRect) -> Placement {
        let content = CGRect(x: (center.x - contentSize.width / 2).rounded(),
                             y: (center.y - contentSize.height / 2).rounded(),
                             width: contentSize.width, height: contentSize.height)
        let frame = clamp(frameAround(content: content, chrome: chrome).frame, into: area)
        return Placement(frame: frame, contentRect: contentRect(forFrame: frame, chrome: chrome))
    }

    /// When another viewer window already sits exactly here, step down-right so both stay visible.
    public static func offsetIfStacked(_ placement: Placement, occupied: [CGRect], step: CGFloat,
                                       chrome: CGFloat, in area: CGRect) -> Placement {
        var frame = placement.frame
        for _ in 0..<12 {
            let stacked = occupied.contains { abs($0.minX - frame.minX) < 2 && abs($0.maxY - frame.maxY) < 2 }
            guard stacked else { break }
            frame.origin.x += step
            frame.origin.y -= step
            if !area.contains(frame) { frame = clamp(frame, into: area); break }
        }
        return Placement(frame: frame, contentRect: contentRect(forFrame: frame, chrome: chrome))
    }

    public static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        if f.maxX > area.maxX { f.origin.x = area.maxX - f.width }
        if f.minX < area.minX { f.origin.x = area.minX }
        if f.maxY > area.maxY { f.origin.y = area.maxY - f.height }
        if f.minY < area.minY { f.origin.y = area.minY }
        return f
    }

    /// The display that shows at least half of `frame`, or nil (e.g. the display it was on is gone).
    static func screen(showing frame: CGRect, in screens: [ScreenGeometry]) -> ScreenGeometry? {
        func overlap(_ s: ScreenGeometry) -> CGFloat {
            let i = frame.intersection(s.visibleFrame)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let best = screens.max(by: { overlap($0) < overlap($1) }),
              overlap(best) >= 0.5 * frame.width * frame.height else { return nil }
        return best
    }

    static func frameAround(content: CGRect, chrome: CGFloat) -> Placement {
        let frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height + chrome)
        return Placement(frame: frame, contentRect: content)
    }

    static func contentRect(forFrame frame: CGRect, chrome: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, frame.height - chrome))
    }
}
