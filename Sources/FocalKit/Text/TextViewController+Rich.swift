import AppKit

/// Rich text (RTF/RTFD): the document's own fonts, colours and pictures, edited with AppKit's format bar.
/// Zoom scales the view (the remembered text size over a 12 pt base) so it never rewrites the document's sizes.
extension TextViewController {
    static let richBaseSize: CGFloat = 12

    var richMagnification: CGFloat { fontSize / Self.richBaseSize }

    func configureRich() {
        textView.isRichText = true
        textView.importsGraphics = true   // pictures pasted or dropped in (saved as RTFD)
        textView.allowsImageEditing = true
        textView.usesFontPanel = true
        textView.usesRuler = true
        textView.usesInspectorBar = true   // TextEdit's format bar: font, size, colours, B/I/U, alignment, lists
        textView.usesAdaptiveColorMappingForDarkAppearance = true   // black-on-white documents stay readable in dark mode
        textView.isAutomaticLinkDetectionEnabled = false
        // Wrap to the window. The width is set by hand (fitRichWidth): autoresizing follows the clip view's frame,
        // but under magnification the visible width is its bounds.
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 10
        // Typing before moving the caret must continue the document's style, not AppKit's Helvetica 12 (the
        // typing font only follows the text once the selection changes; measured: "Z" typed at the start of a
        // Times document came out Helvetica).
        let storage = document.storage
        if storage.length > 0 {
            var style = storage.attributes(at: 0, effectiveRange: nil)
            style[.attachment] = nil   // a document that opens with a picture: type text, not another picture
            textView.typingAttributes = style
        }
    }

    func observeRichResize() {
        scrollView.contentView.postsFrameChangedNotifications = true
        observe(NSView.frameDidChangeNotification, of: scrollView.contentView) { [weak self] in self?.fitRichWidth() }
    }

    func applyRichZoom() {
        let visible = scrollView.contentView.bounds
        scrollView.setMagnification(richMagnification, centeredAt: NSPoint(x: visible.minX, y: visible.minY))
        fitRichWidth()
    }

    func fitRichWidth() {
        let width = scrollView.contentView.bounds.width
        guard abs(textView.frame.width - width) > 0.5 else { return }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    // MARK: Bold / Italic toggles (toolbar format bar, Format menu, ⌘B / ⌘I)

    @objc func toggleBold(_ sender: Any?) { toggleTrait(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { toggleTrait(.italicFontMask) }

    /// Through NSFontManager, as the Font menu does, so the text view converts each run and records one undo step.
    /// Whether to add or remove follows the font at the start of the selection (or the typing font).
    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let selection = textView.selectedRange()
        let storage = document.storage
        let current = (selection.length > 0 && selection.location < storage.length
            ? storage.attribute(.font, at: selection.location, effectiveRange: nil)
            : textView.typingAttributes[.font]) as? NSFont ?? NSFont.userFont(ofSize: Self.richBaseSize) ?? .systemFont(ofSize: Self.richBaseSize)
        let carrier = NSMenuItem()   // the font manager reads the trait from its sender's tag
        carrier.tag = Int(trait.rawValue)
        if manager.traits(of: current).contains(trait) { manager.removeFontTrait(carrier) } else { manager.addFontTrait(carrier) }
    }

    /// A page-wide column (about 100 characters of 12 pt text) at the current zoom, as tall as the text
    /// (measured on a copy at that width), so short notes open small and long ones fill the screen.
    func richNaturalSize() -> CGSize {
        let column: CGFloat = 620
        var height: CGFloat = 900
        if document.storage.length < 200_000 {
            let probe = NSTextStorage(attributedString: document.storage)
            let layout = NSLayoutManager()
            probe.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: column, height: .greatestFiniteMagnitude))
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            height = max(260, layout.usedRect(for: container).height)
        }
        let padding = 2 * (textView.textContainer?.lineFragmentPadding ?? 5)
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let m = richMagnification
        return CGSize(width: ((column + padding + 2 * Self.inset.width) * m + scroller).rounded(.up),
                      height: ((height + 2 * Self.inset.height) * m).rounded(.up))
    }
}
