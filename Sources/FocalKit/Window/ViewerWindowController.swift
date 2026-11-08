import AppKit
import UniformTypeIdentifiers

/// What a viewer window shows (an image or a video).
@MainActor
protocol ViewerContent: AnyObject {
    var supportsMarkup: Bool { get }
    /// Which toolbar the window shows for this content; nil for none (video).
    var toolbarKind: ViewerToolbar.Kind? { get }
    /// Pictures keep their shape when shrunk to fit the screen; text doesn't (it re-wraps).
    var keepsAspectRatio: Bool { get }
    /// Size of the media at 100 %, in points (may need an async read, e.g. video tracks).
    func resolveNaturalSize(_ completion: @escaping @MainActor (CGSize) -> Void)
    func inspectorRows() async -> [(String, String)]
    func teardown()
    /// The view that should have the keyboard (canvas, text, player).
    var keyView: NSView? { get }
    /// The Markup bar's tools for this content, and its help line for a tool (nil: the generic one).
    var markupTools: [MarkupState.Tool] { get }
    func markupHint(for tool: MarkupState.Tool) -> String?
}

extension ViewerContent {
    var toolbarKind: ViewerToolbar.Kind? { .image }
    var keepsAspectRatio: Bool { true }
    var keyView: NSView? { nil }
    var markupTools: [MarkupState.Tool] { MarkupState.Tool.imageTools }
    func markupHint(for tool: MarkupState.Tool) -> String? { nil }
}

extension ScreenGeometry {
    @MainActor static func current() -> [ScreenGeometry] {
        NSScreen.screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}

/// One window per file (or per set of files opened together, browsed from the sidebar). Places itself by the
/// user's rule (center of the main display by default) instead of AppKit's cascade from the top-left, and steps
/// to the next file in place.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let markup = MarkupState()
    private let container = NSView()
    private(set) var content: (NSViewController & ViewerContent)?
    private var hasPlaced = false
    /// True once the person drags or resizes the window; until then each new file is placed by the rule.
    private var userMovedWindow = false
    private var settingFrame = false
    private var siblingCache: (folder: URL, files: [URL])?
    private var pendingNavigation: (() -> Void)?
    private let imageToolbar = ViewerToolbar(kind: .image)
    private lazy var textToolbar = ViewerToolbar(kind: .text)
    private lazy var markdownToolbar = ViewerToolbar(kind: .markdown)
    private lazy var videoToolbar = ViewerToolbar(kind: .video)   // only while the sidebar shows (it holds its button)
    private lazy var pdfToolbar = ViewerToolbar(kind: .pdf)
    private lazy var modelToolbar = ViewerToolbar(kind: .model)
    /// Where the viewer goes: the whole window, or what's right of the sidebar.
    private let mediaArea = NSLayoutGuide()
    private var mediaLeading: NSLayoutConstraint?
    private(set) lazy var sidebar = FileSidebarController()
    private(set) var sidebarVisible = false
    /// Files opened together (several selected in Finder); nil = browse the current file's folder.
    private(set) var fileSet: [URL]?
    /// The sidebar had the keyboard when this file was chosen: keep it there so ↑/↓ keeps stepping.
    private(set) var sidebarKeepsFocus = false
    /// The window's size is a lightbox's (opened as a set, or files switched while browsing), not the file's.
    private var sizedAsLightbox = false
    private lazy var markupBar = MarkupAccessoryController(state: markup)
    private var markupObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: Self.minContentWidth, height: 220)
        window.toolbarStyle = .unified
        super.init(window: window)
        shouldCascadeWindows = false
        windowFrameAutosaveName = ""
        window.delegate = self
        container.frame = window.contentView?.bounds ?? .zero
        window.contentView = container
        container.addLayoutGuide(mediaArea)
        let leading = mediaArea.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        mediaLeading = leading
        NSLayoutConstraint.activate([
            leading,
            mediaArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mediaArea.topAnchor.constraint(equalTo: container.topAnchor),
            mediaArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        markupObserver = NotificationCenter.default.addObserver(forName: MarkupState.didChange, object: markup, queue: .main) { [weak self] note in
            let property = MarkupState.property(of: note)
            MainActor.assumeIsolated {
                if property == .visible { self?.syncMarkupBar() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let markupObserver { NotificationCenter.default.removeObserver(markupObserver) }
    }

    override var document: AnyObject? {
        didSet {
            guard let doc = document as? NSDocument, doc !== oldValue else { return }
            install(for: doc)
        }
    }

    // MARK: Content

    private func install(for doc: NSDocument) {
        let new: NSViewController & ViewerContent
        if let image = doc as? ImageDocument {
            new = ImageViewController(document: image, markup: markup)
        } else if let video = doc as? VideoDocument {
            new = VideoViewController(document: video)
        } else if let text = doc as? TextDocument {
            new = TextViewController(document: text)
        } else if let pdf = doc as? PDFFileDocument {
            new = PDFViewerController(document: pdf, markup: markup)
        } else if let model = doc as? ModelDocument {
            new = ModelViewController(document: model)
        } else {
            return
        }
        if let old = content {
            old.teardown()
            old.view.removeFromSuperview()
        }
        content = new
        window?.subtitle = ""   // the new viewer sets its own; a video after a photo kept "2400 × 1400 · 100%"
        // Toolbar first (it changes the content height), then pin the view to the media area so it always
        // matches the window's content area (a copied frame went stale when the toolbar changed).
        refreshToolbar()
        new.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(new.view)
        NSLayoutConstraint.activate([
            new.view.leadingAnchor.constraint(equalTo: mediaArea.leadingAnchor),
            new.view.trailingAnchor.constraint(equalTo: mediaArea.trailingAnchor),
            new.view.topAnchor.constraint(equalTo: mediaArea.topAnchor),
            new.view.bottomAnchor.constraint(equalTo: mediaArea.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        if sidebarVisible {
            sidebar.select(doc.fileURL)
            if sidebarKeepsFocus { window?.makeFirstResponder(sidebar.table) }
        }
        syncMarkupBar()
        window?.toolbar?.validateVisibleItems()
        if hasPlaced { mediaSizeChanged() }
        InspectorController.refreshIfOpen()
    }

    /// The toolbar for what's showing. Also called when a saved file changes kind ("Untitled" saved as "notes.md").
    func refreshToolbar() {
        let toolbar: NSToolbar? = switch content?.toolbarKind {
        case .image: imageToolbar.toolbar
        case .text: textToolbar.toolbar
        case .markdown: markdownToolbar.toolbar
        case .video: videoToolbar.toolbar
        case .pdf: pdfToolbar.toolbar
        case .model: modelToolbar.toolbar
        case nil: sidebarVisible ? videoToolbar.toolbar : nil   // a plain video window stays toolbar-free
        }
        if window?.toolbar !== toolbar { programmaticFrameChange { window?.toolbar = toolbar } }
    }

    private static let minContentWidth: CGFloat = 360

    private func syncMarkupBar() {
        let show = markup.isVisible && (content?.supportsMarkup ?? false)
        markupBar.setTools(content?.markupTools ?? MarkupState.Tool.imageTools)
        markupBar.hintProvider = { [weak self] tool in self?.content?.markupHint(for: tool) }
        // Added only while shown: a merely hidden accessory still imposes its minimum width on the window
        // (measured: a portrait video after an image with Markup kept a 779 pt window and slid off center).
        if show {
            if markupBar.parent == nil { window?.addTitlebarAccessoryViewController(markupBar) }
        } else if markupBar.parent != nil {
            markupBar.removeFromParent()
        }
        imageToolbar.setMarkupActive(show)
        if content?.toolbarKind == .pdf { pdfToolbar.setMarkupActive(show) }
        guard let window else { return }
        // The Markup tools need room: never let the window be narrower than the bar, and widen it
        // around its center when Markup comes on in a small window.
        let needed = (show ? max(Self.minContentWidth, markupBar.essentialWidth) : Self.minContentWidth)
            + (sidebarVisible ? FileSidebarController.width : 0)
        window.contentMinSize.width = needed
        if show, window.frame.width < needed, !window.styleMask.contains(.fullScreen) {
            var f = window.frame
            f.origin.x -= (needed - f.width) / 2
            f.size.width = needed
            if let area = window.screen?.visibleFrame { f = WindowPlacement.clamp(f, into: area) }
            programmaticFrameChange { window.setFrame(f, display: true) }
            Log.event("markup widen wanted=\(NSStringFromRect(f)) got=\(NSStringFromRect(window.frame))")
        }
    }

    /// Frame changes made by the app (not the person) must not count as "the user moved it".
    private func programmaticFrameChange(_ body: () -> Void) {
        settingFrame = true
        body()
        settingFrame = false
    }

    // MARK: Placement

    /// Title bar + toolbar (+ markup bar): everything above the picture.
    private var chromeHeight: CGFloat {
        guard let window, let cv = window.contentView else { return 0 }
        return window.frame.height - cv.frame.height
    }

    override func showWindow(_ sender: Any?) {
        guard !hasPlaced, let content else {
            super.showWindow(sender)
            return
        }
        content.resolveNaturalSize { [weak self] size in
            guard let self, let window = self.window else { return }
            self.placeInitially(mediaSize: size)
            self.hasPlaced = true
            window.makeKeyAndOrderFront(sender)
            Log.event("window shown frame=\(NSStringFromRect(window.frame)) content=\(NSStringFromRect(window.convertToScreen(window.contentView!.frame)))")
        }
    }

    private func placeInitially(mediaSize: CGSize) {
        guard let window else { return }
        let screens = ScreenGeometry.current()
        // Browsing a set: a roomy lightbox that keeps its size from file to file, whatever the first one is.
        let media = sidebarVisible ? CGSize(width: max(mediaSize.width, 1100), height: max(mediaSize.height, 760)) : mediaSize
        let request = PlacementRequest(mediaSize: media, chromeHeight: chromeHeight, policy: Prefs.placement,
                                       screens: screens, pointer: NSEvent.mouseLocation, lastFrame: Prefs.lastFrame,
                                       fitFraction: Prefs.fitFraction, allowUpscale: Prefs.allowUpscale,
                                       // The real minimum (the Markup bar's width) minus the sidebar, which is added after:
                                       // without the Markup width a small photo was centered at 450 pt, then AppKit grew
                                       // the window to 779 pt to the right only (164 pt off center).
                                       minContentSize: CGSize(width: window.contentMinSize.width - (sidebarVisible ? FileSidebarController.width : 0),
                                                              height: window.contentMinSize.height),
                                       preserveAspect: sidebarVisible ? false : content?.keepsAspectRatio ?? true)
        var placement = WindowPlacement.place(request)
        if sidebarVisible, Prefs.placement != .rememberLastPosition {
            // The sidebar extends to the left: the picture keeps the display's center.
            placement.frame = widenedForSidebar(placement.frame, by: FileSidebarController.width)
        }
        sizedAsLightbox = sidebarVisible
        if Prefs.offsetStackedWindows, Prefs.placement != .rememberLastPosition {
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.windowController is ViewerWindowController }.map(\.frame)
            let area = screens.first { $0.visibleFrame.contains(CGPoint(x: placement.frame.midX, y: placement.frame.midY)) }?.visibleFrame
                ?? screens.first?.visibleFrame ?? placement.frame
            placement = WindowPlacement.offsetIfStacked(placement, occupied: others, step: 24, chrome: chromeHeight, in: area)
        }
        programmaticFrameChange { window.setFrame(placement.frame, display: false) }
    }

    /// New media in this window (next file, rotation, crop). Not moved by the person: placed by the rule
    /// again (exactly centered, no drift). Moved: re-fitted around where they put it.
    func mediaSizeChanged() {
        if sidebarVisible { sizedAsLightbox = true; return }   // a lightbox keeps its size from file to file
        guard let window, let content, hasPlaced, !window.styleMask.contains(.fullScreen),
              Prefs.placement != .rememberLastPosition else { return }
        content.resolveNaturalSize { [weak self] size in
            guard let self, let window = self.window, let cv = window.contentView else { return }
            let current = window.convertToScreen(cv.frame)
            let area: CGRect
            let center: CGPoint
            if self.userMovedWindow {
                area = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? current
                center = CGPoint(x: current.midX, y: current.midY)
            } else {
                let screen = Prefs.placement == .centerOnMainDisplay ? NSScreen.screens.first : (window.screen ?? NSScreen.screens.first)
                area = screen?.visibleFrame ?? current
                center = CGPoint(x: area.midX, y: area.midY)
            }
            let p = WindowPlacement.refit(mediaSize: size, chrome: self.chromeHeight, keepingCenter: center, in: area,
                                          fitFraction: Prefs.fitFraction, allowUpscale: Prefs.allowUpscale,
                                          minContent: window.contentMinSize, preserveAspect: content.keepsAspectRatio)
            self.programmaticFrameChange { window.setFrame(p.frame, display: true) }
            Log.event("refit wanted=\(NSStringFromRect(p.frame)) got=\(NSStringFromRect(window.frame)) minContent=\(window.contentMinSize)")
        }
    }

    private func rememberFrame() {
        guard hasPlaced, let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        Prefs.lastFrame = window.frame
    }

    func windowDidMove(_ notification: Notification) {
        if hasPlaced, !settingFrame, window?.inLiveResize == false { userMovedWindow = true }
        rememberFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userMovedWindow = true
        rememberFrame()
    }
    func windowDidBecomeKey(_ notification: Notification) { siblingCache = nil }

    func windowWillClose(_ notification: Notification) {
        rememberFrame()
        content?.teardown()
    }

    // MARK: Folder navigation

    @objc func nextFile(_ sender: Any?) { navigate(by: 1) }
    @objc func previousFile(_ sender: Any?) { navigate(by: -1) }

    func navigate(by offset: Int) {
        guard let doc = document as? NSDocument, let url = doc.fileURL,
              let target = FolderNavigator.neighbor(of: url, in: browseList(for: url), offset: offset) else {
            NSSound.beep()
            return
        }
        replaceDocument(with: target)
    }

    private func siblings(of url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        if let cache = siblingCache, cache.folder == folder,
           cache.files.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
            return cache.files
        }
        let files = FolderNavigator.siblings(of: url)
        siblingCache = (folder, files)
        return files
    }

    func replaceDocument(with url: URL) {
        guard let old = document as? NSDocument else { return }
        sidebarKeepsFocus = sidebarVisible && window?.firstResponder === sidebar.table
        let swap: () -> Void = { [weak self] in self?.swap(from: old, to: url) }
        if old.isDocumentEdited {
            pendingNavigation = swap
            old.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
        } else {
            swap()
        }
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let action = pendingNavigation
        pendingNavigation = nil
        if shouldClose { action?() }
    }

    /// Move this window (and its position) from one document to the next.
    private func swap(from old: NSDocument, to url: URL) {
        let controller = NSDocumentController.shared
        if let existing = controller.document(for: url) {
            existing.showWindows()
            return
        }
        do {
            let type = try controller.typeForContents(of: url)
            let doc = try controller.makeDocument(withContentsOf: url, ofType: type)
            controller.addDocument(doc)
            old.removeWindowController(self)
            doc.addWindowController(self)
            old.close()
            controller.noteNewRecentDocument(doc)
        } catch {
            window?.presentError(error)
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = (document as? NSDocument)?.fileURL else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// File ▸ Export as PDF…: a PDF copy (a picture becomes a page at its print size, every page of a TIFF a page).
    @objc func exportAsPDF(_ sender: Any?) {
        guard let doc = document as? NSDocument, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.fileURL?.deletingPathExtension().lastPathComponent ?? doc.displayName ?? "Untitled") + ".pdf"
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.export(doc, to: url, type: UTType.pdf.identifier) }
        }
    }

    /// Write a copy in another format and say so in the window; the document stays as it is.
    func export(_ doc: NSDocument, to url: URL, type: String) {
        doc.save(to: url, ofType: type, for: .saveToOperation) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    Log.event("export failed \(url.lastPathComponent): \(error.localizedDescription)")
                    self.window?.presentError(error)
                } else if let view = self.content?.view {
                    Toast.show("Exported \(url.lastPathComponent)", in: view)
                    Log.event("exported \(url.path)")
                }
            }
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let doc = document as? NSDocument, let url = doc.fileURL else { NSSound.beep(); return }
        let files = browseList(for: url)
        let next = FolderNavigator.neighbor(of: url, in: files, offset: 1) ?? FolderNavigator.neighbor(of: url, in: files, offset: -1)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            window?.presentError(error)
            return
        }
        siblingCache = nil
        fileSet?.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        if sidebarVisible { sidebar.show(browseList(for: next ?? url), current: next) }
        doc.updateChangeCount(.changeCleared)   // the file is in the Trash; nothing left to save
        if let next { swap(from: doc, to: next) } else { doc.close() }
    }

    // MARK: PDF search field (in the toolbar)

    func focusSearchField() { pdfToolbar.searchItem?.beginSearchInteraction() }
    func setSearchText(_ text: String) { pdfToolbar.searchItem?.searchField.stringValue = text }

    // MARK: Sidebar (several files in one window)

    /// The files this window steps through: the ones opened together, or the current file's folder.
    func browseList(for url: URL) -> [URL] { fileSet ?? siblings(of: url) }

    /// Several files opened at once: show them in the sidebar. Called before the window is first shown, so it
    /// is placed as a lightbox from the start.
    func browse(_ files: [URL]) {
        fileSet = files
        setSidebar(visible: true)
    }

    /// Toolbar button, View ▸ Show Sidebar (⌥⌘S). For a single file it lists the file's folder.
    @objc func toggleFileSidebar(_ sender: Any?) { setSidebar(visible: !sidebarVisible) }

    func setSidebar(visible: Bool) {
        guard visible != sidebarVisible, let window else { return }
        let current = (document as? NSDocument)?.fileURL
        sidebarVisible = visible
        if visible {
            if sidebar.view.superview == nil {
                sidebar.view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(sidebar.view)
                NSLayoutConstraint.activate([
                    sidebar.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    sidebar.view.topAnchor.constraint(equalTo: container.topAnchor),
                    sidebar.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    sidebar.view.widthAnchor.constraint(equalToConstant: FileSidebarController.width),
                ])
                sidebar.onSelect = { [weak self] url in self?.replaceDocument(with: url) }
            }
            sidebar.view.isHidden = false
            sidebar.show(current.map(browseList(for:)) ?? fileSet ?? [], current: current)
        } else {
            sidebar.view.isHidden = true
        }
        mediaLeading?.constant = visible ? FileSidebarController.width : 0
        (content as? VideoViewController)?.applyAspectLock()   // a lightbox isn't locked to one video's shape
        refreshToolbar()
        if hasPlaced, !window.styleMask.contains(.fullScreen) {
            // Grow or shrink on the left, so whatever is showing stays where it is on screen. Before the
            // minimum-width check below, or that widens the window for the sidebar a second time.
            let width = FileSidebarController.width
            var frame = window.frame
            if visible { frame = widenedForSidebar(frame, by: width) } else { frame.origin.x += width; frame.size.width -= width }
            programmaticFrameChange { window.setFrame(frame, display: true) }
        }
        syncMarkupBar()   // minimum width includes the sidebar
        if !visible {
            // After browsing, size the window for the file again; a plain show/hide returns exactly where it was.
            if hasPlaced, sizedAsLightbox { mediaSizeChanged() }
            sizedAsLightbox = false
            if let key = content?.keyView { window.makeFirstResponder(key) }
        }
    }

    private func widenedForSidebar(_ frame: CGRect, by width: CGFloat) -> CGRect {
        var f = frame
        f.origin.x -= width
        f.size.width += width
        let area = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame ?? f
        return WindowPlacement.clamp(f, into: area)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextFile(_:)), #selector(previousFile(_:)), #selector(moveToTrash(_:)), #selector(showInFinder(_:)):
            return (document as? NSDocument)?.fileURL != nil
        case #selector(exportAsPDF(_:)):
            return (document as? ImageDocument)?.state != nil || (document as? PDFFileDocument)?.pdf.isLocked == false
        case #selector(toggleFileSidebar(_:)):
            item.title = sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return (document as? NSDocument)?.fileURL != nil
        default:
            return true
        }
    }
}

extension NSViewController {
    /// Viewers take the keyboard when they appear, except while the person steps through the sidebar with ↑/↓.
    var mayTakeKeyboardFocus: Bool {
        (view.window?.windowController as? ViewerWindowController)?.sidebarKeepsFocus != true
    }
}
