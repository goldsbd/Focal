import AppKit
import UniformTypeIdentifiers

/// Text window content: big, readable, zoomable and editable; the size you zoom to is remembered for every text
/// window. Plain text and Markdown share one editor (Markdown also has a rendered view, +Markdown); rich text
/// keeps its own fonts, so its zoom scales the view instead (+Rich).
final class TextViewController: NSViewController, ViewerContent, NSTextViewDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    enum Mode { case edit, preview }

    let document: TextDocument
    let scrollView = NSScrollView()
    let textView: ZoomableTextView
    /// Fixed for the window's life; plain text can still become Markdown when saved as .md.
    let isRich: Bool
    private(set) var fontSize: CGFloat
    var mode: Mode = .edit
    var preview: MarkdownPreview?
    private var monospaced = Prefs.textMonospaced
    private var wraps = Prefs.textWraps
    private var observers: [NSObjectProtocol] = []
    private var pendingRecount: DispatchWorkItem?
    static let inset = NSSize(width: 28, height: 22)
    static let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48, 56, 64, 72, 84, 96]

    init(document: TextDocument) {
        self.document = document
        isRich = document.format == .rich
        fontSize = Self.clamp(Prefs.textFontSize)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true   // big logs open instantly; layout happens as you scroll
        document.storage.addLayoutManager(layout)   // the document owns the text; this window shows and edits it
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        textView = ZoomableTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var supportsMarkup: Bool { false }
    var toolbarKind: ViewerToolbar.Kind? { document.format == .markdown ? .markdown : .text }
    var keepsAspectRatio: Bool { false }
    var keyView: NSView? { mode == .preview ? preview?.webView : textView }

    var font: NSFont {
        monospaced ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        // Never auto-hide: with classic scroll bars (a mouse attached) an appearing/disappearing bar changes the
        // text width by 15 pt mid-layout, lines re-wrap, the height crosses back, and AppKit loops forever inside
        // one layout pass (measured: a 4 KB tqdm log hung Focal at 100% CPU, 1.7 GB). The width is reserved anyway.
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true   // into the document's undo manager (delegate below): edited dot, close prompt
        textView.delegate = self
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = Self.inset
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.onZoom = { [weak self] factor in
            guard let self else { return }
            self.setFontSize(self.fontSize * factor)
        }
        if isRich { configureRich() } else { configurePlain() }
        scrollView.documentView = textView
        container.addSubview(scrollView)
        view = container

        let center = NotificationCenter.default
        // Follow the remembered size / font / wrapping when they change (another window zoomed, or Settings).
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
        // Typing, pasting and Revert to Saved all edit the storage: refresh the line count once they pause.
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: document.storage, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageEdited() }
        })
        if isRich { observeRichResize() }
        if document.format == .markdown { setMode(.preview) }   // Markdown opens rendered
    }

    func observe(_ name: Notification.Name, of object: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        })
    }

    /// A plain-text editor: what you type is what's saved. No smart quotes/dashes, no autocorrect, no red
    /// squiggles under log lines and code, no links or data detectors.
    private func configurePlain() {
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        applyStyle()
        applyWrapping()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mayTakeKeyboardFocus { view.window?.makeFirstResponder(mode == .preview ? preview?.webView : textView) }
        syncModeControl()
        updateSubtitle()
        if isRich { applyRichZoom() }
    }

    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pendingRecount?.cancel()
        preview?.teardown()
        if let layout = textView.layoutManager { document.storage.removeLayoutManager(layout) }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    /// Font and colour on all the text and on what you type next (an empty file has no character to copy them
    /// from). Attribute changes aren't undo steps, so zooming never marks the file edited. Plain text only.
    private func applyStyle() {
        let storage = document.storage
        storage.beginEditing()
        storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = attributes
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        if wraps {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.frame.size.width = scrollView.contentSize.width
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            scrollView.hasHorizontalScroller = true
        }
    }

    // MARK: Size

    private static func clamp(_ size: CGFloat) -> CGFloat {
        ((min(max(size, 8), 120)) * 2).rounded() / 2
    }

    /// The rendered Markdown page is 16 px at zoom 1, so it reads at the same size as the editor.
    var previewZoom: CGFloat { fontSize / 16 }

    /// Change the text size, keep the line you were reading at the top, and remember the size.
    func setFontSize(_ proposed: CGFloat) {
        let size = Self.clamp(proposed)
        guard size != fontSize else { return }
        fontSize = size
        applySize()
        Prefs.textFontSize = size
        updateSubtitle()
    }

    private func applySize() {
        if isRich { applyRichZoom() } else { restyleKeepingPosition() }
        preview?.setZoom(previewZoom)
    }

    private func restyleKeepingPosition() {
        guard let storage = textView.textStorage, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let top = NSPoint(x: Self.inset.width, y: scrollView.contentView.bounds.minY + Self.inset.height)
        let anchor = storage.length > 0 ? layout.characterIndex(for: top, in: container, fractionOfDistanceBetweenInsertionPoints: nil) : 0
        applyStyle()
        guard storage.length > 0, anchor > 0 else { return }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: anchor, length: 0), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        textView.scroll(NSPoint(x: 0, y: rect.minY))
    }

    private func preferencesChanged() {
        let size = Self.clamp(Prefs.textFontSize)
        if size != fontSize {
            fontSize = size
            applySize()
            updateSubtitle()
        }
        guard !isRich else { return }   // a rich document's fonts and wrapping are its own
        let mono = Prefs.textMonospaced
        let wrap = Prefs.textWraps
        if mono != monospaced {
            monospaced = mono
            restyleKeepingPosition()
        }
        if wrap != wraps {
            wraps = wrap
            applyWrapping()
        }
    }

    @objc func zoomIn(_ sender: Any?) { setFontSize(Self.sizes.first { $0 > fontSize } ?? fontSize) }
    @objc func zoomOut(_ sender: Any?) { setFontSize(Self.sizes.last { $0 < fontSize } ?? fontSize) }
    @objc func actualSize(_ sender: Any?) { setFontSize(CGFloat(Prefs.defaultTextSize)) }

    // MARK: Editing and saving

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    /// Right-click: Save at the top, then the standard text menu (Cut/Copy/Paste, Spelling, Font…).
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let save = NSMenuItem(title: "Save", action: #selector(quickSave(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        for (index, item) in [save, saveAs, .separator()].enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    /// Save in place in the file's own format, then confirm in the window. An untitled text asks for a name;
    /// any extension works ("notes.md" makes it Markdown). Toolbar button, ⌘S and right-click all come here.
    @objc func quickSave(_ sender: Any?) {
        Log.event("quickSave text edited=\(document.isDocumentEdited)")
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave else {
            // NSDocument has already shown the error (or the person cancelled); keep a trace for diagnosis.
            Log.event("save failed or cancelled: \(doc.fileURL?.path ?? doc.displayName ?? "")")
            return
        }
        let name: String = doc.fileURL?.lastPathComponent ?? doc.displayName ?? "text"
        Toast.show(document.lastSaveSwitchedEncoding ? "Saved \(name) as UTF-8" : "Saved \(name)", in: view)
        // Saved under a new name: "Untitled" → "notes.md" turns on the Markdown preview switch.
        (view.window?.windowController as? ViewerWindowController)?.refreshToolbar()
        syncModeControl()
        updateSubtitle()
        Log.event("saved \(doc.fileURL?.path ?? "") \(document.encodingName) \(document.lineEnding.rawValue) format=\(document.format)")
    }

    private func storageEdited() {
        guard document.storage.editedMask.contains(.editedCharacters) else { return }   // zoom restyles don't count
        pendingRecount?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.document.recount()
                self.updateSubtitle()
                if self.mode == .preview { self.rerenderPreview() }   // Revert to Saved while reading
                InspectorController.refreshIfOpen()
            }
        }
        pendingRecount = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(actualSize(_:)) { item.title = "Default Text Size" }
        if item.action == #selector(togglePreview(_:)) { item.title = mode == .preview ? "Edit Markdown" : "Preview Markdown" }
        return validate(item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }

    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(quickSave(_:)): document.isDocumentEdited || document.fileURL == nil
        case #selector(togglePreview(_:)), #selector(markdownModeChanged(_:)): document.format == .markdown
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)): isRich && mode == .edit
        default: true
        }
    }

    func updateSubtitle() {
        if isRich {
            view.window?.subtitle = "\(Int((richMagnification * 100).rounded()))% · \(document.encodingName)"
            return
        }
        let lines = document.lineCount.formatted()
        let ending = document.lineEnding == .lf ? "" : " · \(document.lineEnding.rawValue)"   // only worth saying when it's Windows/classic Mac
        view.window?.subtitle = "\(fontSize.formatted()) pt · \(lines) line\(document.lineCount == 1 ? "" : "s") · \(document.encodingName)\(ending)"
    }

    // MARK: ViewerContent

    /// About 100 columns (fewer for narrow files) by as many lines as fit; the placement rule caps it to the
    /// screen. A new, empty file gets room to write in. Rich text sizes to a page (+Rich).
    func resolveNaturalSize(_ completion: @escaping @MainActor (CGSize) -> Void) {
        if isRich { completion(richNaturalSize()); return }
        let f = font
        let isNew = document.fileURL == nil && document.storage.length == 0
        // Measured, not estimated: one column = width of "0" in this font (exact for monospaced).
        let charWidth = ("0" as NSString).size(withAttributes: [.font: f]).width
        let columns = CGFloat(isNew ? 90 : min(max(document.longestLine, 48), 100) + 1)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: f) ?? f.pointSize * 1.3
        let lines = CGFloat(isNew ? 28 : min(max(document.lineCount, 6), 200))
        // Everything beside the text: container padding (both sides), insets, and room for a classic scroll
        // bar. Always reserved: with "show scroll bars automatically" the style can flip to classic only after
        // the window is sized (measured: overlay at placement, legacy a moment later), which re-wrapped lines.
        let padding = 2 * (textView.textContainer?.lineFragmentPadding ?? 5)
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        completion(CGSize(width: (columns * charWidth + padding + 2 * Self.inset.width + scroller).rounded(.up),
                          height: (lines * lineHeight + 2 * Self.inset.height).rounded(.up)))
    }

    func inspectorRows() async -> [(String, String)] {
        var rows: [(String, String)] = []
        if let url = document.fileURL {
            rows.append(("File", url.lastPathComponent))
            rows.append(("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                rows.append(("Kind", type.localizedDescription ?? type.identifier))
            }
        }
        if isRich {
            rows.append(("Format", document.encodingName))
            rows.append(("Zoom", "\(Int((richMagnification * 100).rounded()))%"))
        } else {
            rows.append(("Encoding", document.encodingName + (document.hasBOM ? " (with BOM)" : "")))
            rows.append(("Line endings", document.lineEnding.rawValue))
            rows.append(("Lines", document.lineCount.formatted()))
            rows.append(("Text size", "\(fontSize.formatted()) pt"))
        }
        rows.append(("Characters", document.text.count.formatted()))
        return rows
    }
}
