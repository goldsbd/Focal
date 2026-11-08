import AppKit
import PDFKit
import UniformTypeIdentifiers

private struct NoteBox: @unchecked Sendable { let note: Notification }

/// PDF window content: PDFKit's view (text selection, links, form filling, pinch zoom) with a page panel,
/// search, markup and page editing around it. The plain wheel scrolls; ⌘-scroll and pinch zoom.
final class PDFViewerController: NSViewController, ViewerContent, NSMenuItemValidation, NSToolbarItemValidation {
    static let sidePanelWidth: CGFloat = 168

    let document: PDFFileDocument
    let markup: MarkupState
    let pdfView = PDFView()
    let overlay = PDFOverlayView()
    let sidePanel = PDFSidePanel()
    private(set) var sidePanelVisible = false
    private var pdfLeading: NSLayoutConstraint?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let unlockButton = NSButton(title: "Unlock…", target: nil, action: nil)
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var askedForPassword = false
    private var lastSubtitle = ""

    // Search (Edit ▸ Find, the toolbar field): every match highlighted, ⌘G steps.
    private(set) var matches: [PDFSelection] = []
    private(set) var matchIndex = -1
    private var found: [PDFSelection] = []
    private(set) var searchText = ""

    // Markup in progress (see PDFViewerController+Markup).
    var interaction = PDFInteraction()
    var selectedMark: (annotation: PDFAnnotation, page: PDFPage)? { didSet { overlay.needsDisplay = true } }
    var pendingCrop: (page: PDFPage, rect: CGRect)? { didSet { overlay.needsDisplay = true } }
    var textEditor: PDFTextEditor?

    init(document: PDFFileDocument, markup: MarkupState) {
        self.document = document
        self.markup = markup
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var supportsMarkup: Bool { document.canAnnotate }
    var toolbarKind: ViewerToolbar.Kind? { .pdf }
    var keepsAspectRatio: Bool { false }
    var keyView: NSView? { pdfView }
    var markupTools: [MarkupState.Tool] { MarkupState.Tool.pdfTools }

    func markupHint(for tool: MarkupState.Tool) -> String? {
        switch tool {
        case .select: "Select text · click a mark to select it, drag to move · Delete removes · double-click edits"
        case .highlighter, .underline, .strikeout: "Select text to mark it"
        case .text: "Click to type · Return finishes · ⌥Return new line"
        case .note: "Click to add a note · double-click a note to read or edit it"
        case .signature: "Click where the signature goes · Tools ▸ Create Signature… makes a new one"
        case .redact: "Solid box: the page is saved as a picture, so the text under it is gone for good"
        case .crop: "Drag to choose the area · Return crops the page · Esc cancels"
        default: nil
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1000))
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.document = document.pdf
        root.addSubview(pdfView)
        let leading = pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        pdfLeading = leading
        NSLayoutConstraint.activate([
            leading,
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        overlay.frame = pdfView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.controller = self
        pdfView.addSubview(overlay)

        message.isHidden = true
        message.alignment = .center
        message.font = .systemFont(ofSize: 15)
        message.textColor = .secondaryLabelColor
        unlockButton.isHidden = true
        unlockButton.bezelStyle = .push
        unlockButton.target = self
        unlockButton.action = #selector(unlockDocument(_:))
        let stack = NSStackView(views: [message, unlockButton])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root
        observe()
        document.onChange = { [weak self] change in self?.documentChanged(change) }
        if document.pdf.isLocked { showLocked() } else { documentReady() }
    }

    /// Unlocked (or never locked): pages, panel and title.
    private func documentReady() {
        message.isHidden = true
        unlockButton.isHidden = true
        pdfView.isHidden = false
        sidePanel.outlineRoot = document.pdf.outlineRoot
        if document.pdf.pageCount > 1 || (document.pdf.outlineRoot?.numberOfChildren ?? 0) > 0 { setSidePanel(visible: true) }
        pageChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mayTakeKeyboardFocus { view.window?.makeFirstResponder(pdfView) }
        lastSubtitle = ""
        updateSubtitle()
        if document.pdf.isLocked, !askedForPassword {
            askedForPassword = true
            unlockDocument(nil)
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: Any?, _ body: @escaping @MainActor (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: object, queue: .main) { note in
                let box = NoteBox(note: note)   // delivered on the main queue; the box only gets it past the checker
                MainActor.assumeIsolated { body(box.note) }
            })
        }
        on(.PDFViewPageChanged, pdfView) { [weak self] _ in self?.pageChanged() }
        on(.PDFViewScaleChanged, pdfView) { [weak self] _ in self?.overlay.needsDisplay = true; self?.updateSubtitle() }
        on(NSView.boundsDidChangeNotification, nil) { [weak self] note in
            // The page scrolled under the overlay: redraw marks in progress where they now are.
            guard let self, let clip = note.object as? NSClipView, clip.isDescendant(of: self.pdfView) else { return }
            self.overlay.needsDisplay = true
            self.textEditor.map { self.positionTextEditor($0) }
        }
        on(.PDFViewAnnotationHit, pdfView) { [weak self] note in
            // Ticking a box or picking from a list changes the form (text fields report through textDidChange).
            if let hit = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation, hit.type == "Widget",
               hit.widgetFieldType != .text { self?.document.formEdited() }
        }
        on(NSControl.textDidChangeNotification, nil) { [weak self] note in
            guard let self, let field = note.object as? NSView, field.isDescendant(of: self.pdfView),
                  !(field is PDFTextEditor) else { return }
            self.document.formEdited()
        }
        on(.PDFDocumentDidFindMatch, document.pdf) { [weak self] note in
            guard let self, let sel = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            self.found.append(sel)
            if self.found.count == 1 { self.matches = [sel]; self.show(match: 0) }   // the first one at once
        }
        on(.PDFDocumentDidEndFind, document.pdf) { [weak self] _ in self?.searchFinished() }
        on(MarkupState.didChange, markup) { [weak self] note in
            guard MarkupState.property(of: note) == .tool || MarkupState.property(of: note) == .visible else { return }
            self?.toolChanged()
        }
        // ⌘-scroll zooms at the pointer (PDFView's own scroll view would only scroll).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.zoomForScroll(event) ?? false } ? nil : event
        }) { monitors.append(m) }
        // Highlight / underline / strike through: PDFKit selects the text, the mouse-up marks it.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseWentUp(event) }
            return event
        }) { monitors.append(m) }
    }

    /// ⌘-scroll over the PDF: zoom at the pointer. True when the event was used.
    private func zoomForScroll(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), event.window === view.window, let factor = ZoomWheel.factor(for: event) else { return false }
        let p = pdfView.convert(event.locationInWindow, from: nil)
        guard pdfView.bounds.contains(p) else { return false }
        zoom(by: factor, at: p)
        return true
    }

    private func mouseWentUp(_ event: NSEvent) {
        guard event.window === view.window, activeTool.marksText else { return }
        // Two hops: the dispatch runs once PDFKit's mouse tracking has finished the selection (an event posted now
        // was pulled out mid-drag by that tracking loop, with the selection half made); the posted event then does
        // the marking inside an event, so it's one closed undo step and the window shows edited at once.
        let window = view.window
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { InEvent.perform(in: window) { self?.markSelectedText() } }
        }
    }

    func teardown() {
        endTextEditing(commit: true)
        document.pdf.cancelFindString()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if document.onChange != nil { document.onChange = nil }
    }

    // MARK: Document

    private func documentChanged(_ change: PDFFileDocument.Change) {
        switch change {
        case .pages:
            selectedMark = nil
            pendingCrop = nil
            pdfView.layoutDocumentView()
            sidePanel.strip.reload(selecting: currentPageIndex)
            updateSubtitle()
        case .annotations(let page):
            pdfView.annotationsChanged(on: page)
            if sidePanelVisible { sidePanel.strip.reload(selecting: currentPageIndex) }   // the thumbnail shows the mark
            if let sel = selectedMark, !sel.page.annotations.contains(sel.annotation) { selectedMark = nil }
        case .unlocked:
            pdfView.document = nil
            pdfView.document = document.pdf
            documentReady()
            view.window?.toolbar?.validateVisibleItems()
        }
        overlay.needsDisplay = true
    }

    var currentPageIndex: Int { pdfView.currentPage.map { document.pdf.index(for: $0) } ?? 0 }

    private func pageChanged() {
        document.currentPageIndex = currentPageIndex
        sidePanel.strip.select(currentPageIndex)
        updateSubtitle()
    }

    func updateSubtitle() {
        guard let window = view.window else { return }
        var parts: [String] = []
        if document.pdf.isLocked {
            parts.append("Locked")
        } else {
            parts.append("Page \(currentPageIndex + 1) of \(document.pdf.pageCount)")
            parts.append("\(Int((pdfView.scaleFactor * 100).rounded()))%")
            if !searchText.isEmpty {
                parts.append(matches.isEmpty ? "No matches" : "\(matchIndex + 1) of \(matches.count) matches")
            }
            if document.isPDFType && !document.canAnnotate { parts.append("Read-only") }
        }
        let s = parts.joined(separator: " · ")
        guard s != lastSubtitle else { return }
        lastSubtitle = s
        window.subtitle = s
    }

    // MARK: Locked PDFs

    private func showLocked() {
        pdfView.isHidden = true
        message.stringValue = "“\(document.displayName ?? "This PDF")” is locked with a password."
        message.isHidden = false
        unlockButton.isHidden = false
    }

    @objc func unlockDocument(_ sender: Any?) {
        guard let window = view.window, document.pdf.isLocked else { return }
        promptForPassword(in: window, wrong: false)
    }

    private func promptForPassword(in window: NSWindow, wrong: Bool) {
        let alert = NSAlert()
        alert.messageText = wrong ? "That password didn't work." : "Enter the password to open this PDF."
        alert.informativeText = document.displayName ?? ""
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                if !self.document.unlock(with: field.stringValue) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.promptForPassword(in: window, wrong: true) } }
                }
            }
        }
    }

    // MARK: Side panel

    @objc func togglePageStrip(_ sender: Any?) { setSidePanel(visible: !sidePanelVisible) }

    func setSidePanel(visible: Bool) {
        guard visible != sidePanelVisible else { return }
        sidePanelVisible = visible
        if visible {
            if sidePanel.view.superview == nil {
                sidePanel.strip.source = self
                sidePanel.strip.onSelect = { [weak self] index in self?.goTo(index) }
                sidePanel.onOutlineSelect = { [weak self] item in self?.go(to: item) }
                sidePanel.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(sidePanel.view)
                NSLayoutConstraint.activate([
                    sidePanel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    sidePanel.view.topAnchor.constraint(equalTo: view.topAnchor),
                    sidePanel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    sidePanel.view.widthAnchor.constraint(equalToConstant: Self.sidePanelWidth),
                ])
            }
            sidePanel.view.isHidden = false
            sidePanel.strip.reload(selecting: currentPageIndex)
        } else {
            sidePanel.view.isHidden = true
        }
        pdfLeading?.constant = visible ? Self.sidePanelWidth : 0
    }

    // MARK: Size and zoom

    func resolveNaturalSize(_ completion: @escaping @MainActor (CGSize) -> Void) {
        var size = CGSize(width: 612, height: 792)   // US Letter until the first page says otherwise
        if !document.pdf.isLocked, let page = document.pdf.page(at: 0) {
            size = page.bounds(for: .cropBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        }
        let margin: CGFloat = 24   // page break shadow and gutters
        let panel = sidePanelVisible || document.pdf.pageCount > 1 ? Self.sidePanelWidth : 0
        completion(CGSize(width: size.width + margin + panel + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy),
                          height: size.height + margin))
    }

    func zoom(by factor: CGFloat, at point: NSPoint) {
        guard let page = pdfView.page(for: point, nearest: true), let clip = pdfView.documentView?.enclosingScrollView?.contentView
        else { return }
        let onPage = pdfView.convert(point, to: page)
        pdfView.scaleFactor = min(max(pdfView.scaleFactor * factor, 0.1), 16)
        // Keep the spot under the pointer where it was.
        let moved = pdfView.convert(onPage, from: page)
        let a = clip.convert(point, from: pdfView), b = clip.convert(moved, from: pdfView)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x + (b.x - a.x), y: clip.bounds.origin.y + (b.y - a.y)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func actualSize(_ sender: Any?) { pdfView.scaleFactor = 1 }

    /// The whole page in the window.
    @objc func zoomToFit(_ sender: Any?) {
        guard let page = pdfView.currentPage else { return }
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let area = pdfView.bounds.insetBy(dx: 12, dy: 12).size
        guard size.width > 0, size.height > 0 else { return }
        pdfView.scaleFactor = min(area.width / size.width, area.height / size.height)
        pdfView.go(to: page)
    }

    /// View ▸ Continuous Scroll / Single Page / Two Pages (the item's tag is the PDFDisplayMode).
    @objc func setPDFDisplayMode(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let mode = PDFDisplayMode(rawValue: tag) else { return }
        pdfView.displayMode = mode
        pdfView.displaysAsBook = mode == .twoUp || mode == .twoUpContinuous
    }

    // MARK: Pages

    @objc func nextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func previousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }

    @objc func goToPage(_ sender: Any?) {
        guard let window = view.window else { return }
        PagePrompt.ask(in: window, pageCount: document.pdf.pageCount, current: currentPageIndex) { [weak self] index in self?.goTo(index) }
    }

    func goTo(_ index: Int) {
        guard let page = document.pdf.page(at: index) else { NSSound.beep(); return }
        pdfView.go(to: page)
    }

    func go(to item: PDFOutline) {
        if let destination = item.destination { pdfView.go(to: destination) } else if let action = item.action { pdfView.perform(action) }
    }

    /// Pages chosen in the panel (when it has the keyboard), else the page showing.
    var targetPages: IndexSet {
        let chosen = sidePanel.strip.selectedPages
        if sidePanelVisible, view.window?.firstResponder === sidePanel.strip.table, !chosen.isEmpty { return chosen }
        return IndexSet(integer: currentPageIndex)
    }

    @objc func rotateLeft(_ sender: Any?) { document.rotate(targetPages, clockwise: false) }
    @objc func rotateRight(_ sender: Any?) { document.rotate(targetPages, clockwise: true) }

    // MARK: Search

    @objc func searchChanged(_ sender: Any?) {
        guard let field = sender as? NSSearchField else { return }
        search(field.stringValue)
    }

    func search(_ text: String) {
        document.pdf.cancelFindString()
        searchText = text
        found = []
        matches = []
        matchIndex = -1
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()   // the old match stays selected otherwise, and picking Highlight would mark it
        if !text.isEmpty { document.pdf.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]) }
        updateSubtitle()
    }

    private func searchFinished() {
        matches = found
        for m in matches { m.color = .findHighlightColor }
        pdfView.highlightedSelections = matches
        if matchIndex < 0, !matches.isEmpty { show(match: 0) }
        updateSubtitle()
    }

    private func show(match index: Int) {
        guard matches.indices.contains(index) else { return }
        matchIndex = index
        pdfView.setCurrentSelection(matches[index], animate: true)
        pdfView.scrollSelectionToVisible(nil)
        updateSubtitle()
    }

    /// Edit ▸ Find (⌘F) goes to the toolbar's search field; Find Next / Previous (⌘G ⇧⌘G) step through matches.
    @objc func performFindPanelAction(_ sender: Any?) {
        let action = NSTextFinder.Action(rawValue: (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue)
        switch action {
        case .nextMatch, .previousMatch:
            guard !matches.isEmpty else { NSSound.beep(); return }
            let step = action == .nextMatch ? 1 : -1
            show(match: (matchIndex + step + matches.count) % matches.count)
        case .setSearchString:
            if let text = pdfView.currentSelection?.string, !text.isEmpty {
                (view.window?.windowController as? ViewerWindowController)?.setSearchText(text)
                search(text)
            }
        default:
            (view.window?.windowController as? ViewerWindowController)?.focusSearchField()
        }
    }

    // MARK: Saving

    @objc func quickSave(_ sender: Any?) {
        endTextEditing(commit: true)
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave else { Log.event("save failed or cancelled: \(doc.fileURL?.path ?? "")"); return }
        Toast.show("Saved \(doc.fileURL?.lastPathComponent ?? "PDF")", in: view)
        Log.event("saved \(doc.fileURL?.path ?? "")")
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePageStrip(_:)):
            item.title = sidePanelVisible ? "Hide Page Thumbnails" : "Show Page Thumbnails"
        case #selector(setPDFDisplayMode(_:)):
            item.state = pdfView.displayMode.rawValue == item.tag ? .on : .off
        case #selector(actualSize(_:)):
            item.title = "Actual Size"
        default:
            break
        }
        return validate(item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }

    private func validate(_ action: Selector?) -> Bool {
        let open = !document.pdf.isLocked
        switch action {
        case #selector(quickSave(_:)):
            return open && document.isPDFType && (document.isDocumentEdited || document.fileURL == nil)
        case #selector(toggleMarkup(_:)), #selector(cropToSelection(_:)):
            return open && document.canAnnotate
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return open && document.canEditPages
        case #selector(nextPage(_:)):
            return open && pdfView.canGoToNextPage
        case #selector(previousPage(_:)):
            return open && pdfView.canGoToPreviousPage
        case #selector(goToPage(_:)), #selector(togglePageStrip(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomToFit(_:)), #selector(actualSize(_:)), #selector(setPDFDisplayMode(_:)), #selector(performFindPanelAction(_:)):
            return open
        case #selector(deleteBackward(_:)), #selector(delete(_:)):
            return selectedMark != nil
        default:
            return true
        }
    }

    // MARK: Inspector

    func inspectorRows() async -> [(String, String)] {
        var rows: [(String, String)] = []
        let pdf = document.pdf
        if let url = document.fileURL {
            rows.append(("File", url.lastPathComponent))
            rows.append(("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
        }
        rows.append(("Kind", document.isPDFType ? "PDF \(pdf.majorVersion).\(pdf.minorVersion)" : "Illustrator (PDF content, read-only)"))
        rows.append(("Pages", "\(pdf.pageCount)"))
        if let page = pdf.page(at: currentPageIndex) {
            let size = page.bounds(for: .cropBox).size
            rows.append(("Page size", String(format: "%.1f × %.1f in  (%.0f × %.0f mm)", size.width / 72, size.height / 72,
                                             size.width / 72 * 25.4, size.height / 72 * 25.4)))
        }
        let attributes = pdf.documentAttributes ?? [:]
        let names: [(PDFDocumentAttribute, String)] = [(.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
                                                       (.creatorAttribute, "Created with"), (.producerAttribute, "Producer")]
        for (key, label) in names {
            if let value = attributes[key] as? String, !value.isEmpty { rows.append((label, value)) }
        }
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], !keywords.isEmpty {
            rows.append(("Keywords", keywords.joined(separator: ", ")))
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        if let d = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date { rows.append(("Created", dates.string(from: d))) }
        if let d = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date { rows.append(("Modified", dates.string(from: d))) }
        rows.append(("Security", pdf.isEncrypted ? (pdf.isLocked ? "Locked" : "Encrypted") : "None"))
        let marks = document.pages.reduce(0) { $0 + $1.annotations.filter(PDFMarks.isMarkup).count }
        if marks > 0 { rows.append(("Markup", "\(marks) mark\(marks == 1 ? "" : "s")")) }
        return rows
    }
}
