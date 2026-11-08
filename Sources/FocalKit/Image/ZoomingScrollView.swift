import AppKit

/// Keeps an image that is smaller than the window centered instead of pinned to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = f.minX - (r.width - f.width) / 2 }
        if r.height > f.height { r.origin.y = f.minY - (r.height - f.height) / 2 }
        return r
    }
}

/// The scroll wheel zooms around the pointer (or scrolls, if the user prefers; ⌘/⌥ flips it).
final class ZoomingScrollView: NSScrollView {
    /// Proposed magnification in, allowed magnification out (the owner snaps to fit).
    var onUserZoom: ((CGFloat) -> CGFloat)?
    /// Called on every step of a window resize with the document point that was at the center before it.
    var onViewportResize: ((NSPoint) -> Void)?
    var wheelZooms: () -> Bool = { true }

    override func setFrameSize(_ newSize: NSSize) {
        let b = contentView.bounds
        let oldCenter = NSPoint(x: b.midX, y: b.midY)
        super.setFrameSize(newSize)
        onViewportResize?(oldCenter)
    }

    /// Scroll so `point` (document coordinates) is in the middle of the view.
    func center(on point: NSPoint) {
        let clip = contentView
        let size = clip.bounds.size
        let origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: size)).origin)
        reflectScrolledClipView(clip)
    }

    override func scrollWheel(with event: NSEvent) {
        let flipped = !event.modifierFlags.intersection([.command, .option]).isEmpty
        guard wheelZooms() != flipped else { super.scrollWheel(with: event); return }
        guard event.momentumPhase.isEmpty else { return }   // trackpad momentum would run the zoom away
        var dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        if event.isDirectionInvertedFromDevice { dy = -dy }   // wheel away from you = zoom in, whatever "natural scrolling" says
        let step = event.hasPreciseScrollingDeltas ? dy * 0.01 : max(-0.6, min(0.6, dy * 0.15))
        // Events without a window report their location in screen coordinates (NSEvent docs).
        let inWindow = event.window == nil ? (window?.convertPoint(fromScreen: event.locationInWindow) ?? event.locationInWindow)
                                           : event.locationInWindow
        zoom(to: magnification * exp(step), keeping: contentView.convert(inWindow, from: nil))
    }

    /// Zoom so the document point at `point` (clip-view coordinates) stays put on screen.
    func zoom(to proposed: CGFloat, keeping point: NSPoint) {
        let target = onUserZoom?(proposed) ?? proposed
        let old = magnification
        guard abs(target - old) > 0.0001 else { return }
        let clip = contentView
        let origin = clip.bounds.origin
        let offset = NSPoint(x: (point.x - origin.x) * old, y: (point.y - origin.y) * old)
        magnification = target
        let newOrigin = NSPoint(x: point.x - offset.x / target, y: point.y - offset.y / target)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: newOrigin, size: clip.bounds.size)).origin)
        reflectScrolledClipView(clip)
    }
}

enum ZoomSteps {
    static let levels: [CGFloat] = [0.02, 0.03, 0.05, 0.0625, 0.083, 0.1, 0.125, 0.167, 0.25, 0.333, 0.5, 0.667,
                                    0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]
    static func next(after m: CGFloat) -> CGFloat { levels.first { $0 > m * 1.01 } ?? levels[levels.count - 1] }
    static func previous(before m: CGFloat) -> CGFloat { levels.last { $0 < m * 0.99 } ?? levels[0] }
}
