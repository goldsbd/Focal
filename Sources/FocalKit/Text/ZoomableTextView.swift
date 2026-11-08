import AppKit

/// ⌘ or ⌥ + wheel → a zoom factor (1 = swallow, no change); nil for a plain wheel, which scrolls (you're reading).
enum ZoomWheel {
    static func factor(for event: NSEvent) -> CGFloat? {
        guard !event.modifierFlags.intersection([.command, .option]).isEmpty else { return nil }
        guard event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 else { return 1 }
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        let step = event.hasPreciseScrollingDeltas ? dy * 0.01 : max(-0.4, min(0.4, dy * 0.1))
        return exp(step)
    }
}

/// Text view that zooms with pinch or ⌘/⌥ + scroll wheel; the plain wheel scrolls.
final class ZoomableTextView: NSTextView {
    var onZoom: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let factor = ZoomWheel.factor(for: event) { onZoom?(factor) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { onZoom?(1 + event.magnification) }

    /// TextEdit's ⌘B / ⌘I / ⌘U / ⌘T while typing rich text. The key window's views see key equivalents before
    /// the menu bar, so inside rich text these beat the app-wide ⌘I (Inspector) and ⌘T (Trim).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRichText, window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "b": return NSApp.sendAction(#selector(TextViewController.toggleBold(_:)), to: nil, from: self)
        case "i": return NSApp.sendAction(#selector(TextViewController.toggleItalic(_:)), to: nil, from: self)
        case "u": underline(nil); return true
        case "t": NSFontManager.shared.orderFrontFontPanel(self); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
