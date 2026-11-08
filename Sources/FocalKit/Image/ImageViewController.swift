import AppKit
import os
import UniformTypeIdentifiers

/// Stop flag shared with ImageIO's animation callback thread.
final class AnimationFlag: Sendable {
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    var isStopped: Bool { stopped.withLock { $0 } }
    func stop() { stopped.withLock { $0 = true } }
}

/// Image window content: zoom (scroll wheel at the pointer, pinch, menu), pan (drag), markup, rotate, crop.
final class ImageViewController: NSViewController, ViewerContent, CanvasViewDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let document: ImageDocument
    let markup: MarkupState
    private let scrollView = ZoomingScrollView()
    let canvas: CanvasView
    private let message = NSTextField(wrappingLabelWithString: "")
    private var fitMode = true
    private var observers: [NSObjectProtocol] = []
    private var animation: AnimationFlag?
    private var lastSubtitle = ""
    private(set) lazy var pageStrip = PageStripController()
    private(set) var pageStripVisible = false
    private var scrollLeading: NSLayoutConstraint?

    init(document: ImageDocument, markup: MarkupState) {
        self.document = document
        self.markup = markup
        canvas = CanvasView(document: document, markup: markup)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var supportsMarkup: Bool { !document.info.isAnimated }
    var naturalSize: CGSize {
        let size = document.canvasPointSize
        return CGSize(width: size.width + (pageStripVisible ? PageStripController.width : 0), height: size.height)
    }
    var magnification: CGFloat { scrollView.magnification }
    var clipBounds: NSRect { scrollView.contentView.bounds }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 64
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.wheelZooms = { Prefs.wheelZooms }
        scrollView.onUserZoom = { [weak self] m in self?.userZoom(m) ?? m }
        scrollView.onViewportResize = { [weak self] center in self?.viewportResized(keeping: center) }
        root.addSubview(scrollView)
        let leading = scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        scrollLeading = leading
        NSLayoutConstraint.activate([
            leading,
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        message.isHidden = true
        message.alignment = .center
        message.font = .systemFont(ofSize: 15)
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
        ])
        view = root

        canvas.delegate = self
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoomDidChange() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveMagnifyEnded() }
        })
        document.onChange = { [weak self] change in self?.documentChanged(change) }
        canvas.reload()
        if document.state != nil { startAnimationIfNeeded() }
        if let error = document.loadError { show(error) }
        if document.pageCount > 1 { setPageStrip(visible: true) }
    }

    /// The page strip sits left of the picture; the window keeps its size (the picture refits).
    func setPageStrip(visible: Bool) {
        guard visible != pageStripVisible, document.pageCount > 1 || !visible else { return }
        pageStripVisible = visible
        if visible {
            if pageStrip.view.superview == nil {
                pageStrip.source = self
                pageStrip.onSelect = { [weak self] page in self?.goTo(page) }
                pageStrip.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(pageStrip.view)
                NSLayoutConstraint.activate([
                    pageStrip.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    pageStrip.view.topAnchor.constraint(equalTo: view.topAnchor),
                    pageStrip.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    pageStrip.view.widthAnchor.constraint(equalToConstant: PageStripController.width),
                ])
            }
            pageStrip.view.isHidden = false
            pageStrip.reload(selecting: document.page)
        } else {
            pageStrip.view.isHidden = true
        }
        scrollLeading?.constant = visible ? PageStripController.width : 0
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mayTakeKeyboardFocus { view.window?.makeFirstResponder(canvas) }
        lastSubtitle = ""
        updateSubtitle()
    }

    var keyView: NSView? { canvas }

    /// Window resized (live): stay fitted if fitted, otherwise keep the zoom and the spot you were looking at.
    private func viewportResized(keeping center: NSPoint) {
        guard canvas.frame.width > 0 else { return }
        let fit = fitMagnification()
        scrollView.minMagnification = fit
        if fitMode || scrollView.magnification < fit {
            applyFit()
        } else {
            scrollView.center(on: center)
        }
    }

    func teardown() {
        animation?.stop()
        canvas.endEditing()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if document.onChange != nil { document.onChange = nil }
    }

    func resolveNaturalSize(_ completion: @escaping @MainActor (CGSize) -> Void) { completion(naturalSize) }

    // MARK: Document

    private func documentChanged(_ change: ImageDocument.Change) {
        switch change {
        case .loaded:
            message.isHidden = true
            canvas.reload()
            startAnimationIfNeeded()
            if fitMode { applyFit() }
            updateSubtitle()
        case .geometry:
            if pageStripVisible { pageStrip.reload(selecting: document.page) }
            canvas.reload()
            (view.window?.windowController as? ViewerWindowController)?.mediaSizeChanged()
            applyFit()
            updateSubtitle()
        case .annotations:
            canvas.annotationsChanged()
            if pageStripVisible { pageStrip.reload(selecting: document.page) }   // the page's thumbnail shows its marks
        case .page:
            message.isHidden = true
            canvas.reload()
            (view.window?.windowController as? ViewerWindowController)?.mediaSizeChanged()
            applyFit()
            updateSubtitle()
            pageStrip.select(document.page)
        case .failed(let text):
            show(text)
        }
    }

    private func show(_ text: String) {
        message.stringValue = text
        message.isHidden = false
    }

    private func startAnimationIfNeeded() {
        guard document.info.isAnimated, animation == nil, let url = document.fileURL else { return }
        let flag = AnimationFlag()
        animation = flag
        let canvas = self.canvas
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, image, stop in
            if flag.isStopped { stop.pointee = true; return }
            let box = ImageBox(image: image)
            DispatchQueue.main.async { MainActor.assumeIsolated { canvas.showFrame(box.image) } }
        }
    }

    // MARK: Zoom

    /// Whole image visible; never above 100 % unless the user allows enlarging.
    func fitMagnification() -> CGFloat {
        let viewport = scrollView.contentView.frame.size
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        var m = min(viewport.width / size.width, viewport.height / size.height)
        if !Prefs.allowUpscale { m = min(m, 1) }
        return max(0.01, min(m, scrollView.maxMagnification))
    }

    func applyFit() {
        fitMode = true
        let m = fitMagnification()
        scrollView.minMagnification = m
        scrollView.setMagnification(m, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        zoomDidChange()
    }

    /// Zooming out stops at "fit" (and re-enters fit mode, so resizing the window keeps it fitted).
    private func userZoom(_ proposed: CGFloat) -> CGFloat {
        let fit = fitMagnification()
        if proposed <= fit * 1.001 {
            fitMode = true
            return fit
        }
        fitMode = false
        return min(proposed, scrollView.maxMagnification)
    }

    private func liveMagnifyEnded() {
        fitMode = abs(scrollView.magnification - fitMagnification()) < 0.001
    }

    private var visibleCenter: NSPoint {
        let b = scrollView.contentView.bounds
        return NSPoint(x: b.midX, y: b.midY)
    }

    @objc func zoomIn(_ sender: Any?) { scrollView.zoom(to: ZoomSteps.next(after: scrollView.magnification), keeping: visibleCenter) }
    @objc func zoomOut(_ sender: Any?) { scrollView.zoom(to: ZoomSteps.previous(before: scrollView.magnification), keeping: visibleCenter) }
    @objc func actualSize(_ sender: Any?) { scrollView.zoom(to: 1, keeping: visibleCenter) }
    @objc func zoomToFit(_ sender: Any?) { applyFit() }

    private func zoomDidChange() {
        canvas.magnificationChanged(scrollView.magnification, backingScale: view.window?.backingScaleFactor ?? 2)
        updateSubtitle()
    }

    private func updateSubtitle() {
        let px = canvas.canvasRect.size
        let pages = document.pageCount > 1 ? "Page \(document.page + 1) of \(document.pageCount) · " : ""
        let s = pages + "\(Int(px.width)) × \(Int(px.height)) · \(Int((scrollView.magnification * 100).rounded()))%"
        guard s != lastSubtitle, let window = view.window else { return }
        lastSubtitle = s
        window.subtitle = s
    }

    // MARK: CanvasViewDelegate

    var canvasMagnification: CGFloat { scrollView.magnification }

    func canvasRequestsNavigation(_ offset: Int) {
        (view.window?.windowController as? ViewerWindowController)?.navigate(by: offset)
    }

    func canvasToggleZoom(at point: NSPoint) {
        if fitMode {
            scrollView.zoom(to: fitMagnification() < 0.99 ? 1 : 2, keeping: point)
        } else {
            applyFit()
        }
    }

    // MARK: Commands

    private var canEdit: Bool { document.state != nil && !document.info.isAnimated }

    @objc func toggleMarkup(_ sender: Any?) {
        guard canEdit else { NSSound.beep(); return }
        markup.isVisible.toggle()
    }

    @objc func rotateLeft(_ sender: Any?) { canvas.endEditing(); document.rotate(clockwise: false) }
    @objc func rotateRight(_ sender: Any?) { canvas.endEditing(); document.rotate(clockwise: true) }

    @objc func cropToSelection(_ sender: Any?) {
        if canvas.hasPendingCrop {
            canvas.applyCrop()
        } else {
            markup.isVisible = true
            markup.tool = .crop
        }
    }

    /// Save in place (no dialog for PNG/JPEG/HEIC/TIFF; a save panel only for new or read-only formats),
    /// then confirm in the window. Toolbar button, ⌘S and the right-click menu all come here.
    @objc func quickSave(_ sender: Any?) {
        canvas.endEditing()
        document.save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave else {
            Log.event("save failed or cancelled: \(doc.fileURL?.path ?? doc.displayName ?? "")")   // NSDocument showed any error
            return
        }
        let name: String = doc.fileURL?.lastPathComponent ?? doc.displayName ?? "image"
        Toast.show("Saved \(name)", in: view)
        Log.event("saved \(doc.fileURL?.path ?? "")")
    }

    @objc func copy(_ sender: Any?) {
        canvas.endEditing()
        guard let image = document.flattenedImage() else { NSSound.beep(); return }
        PasteboardImage.write(image, pointSize: document.canvasPointSize)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMarkup(_:)) {
            item.title = markup.isVisible ? "Hide Markup Toolbar" : "Show Markup Toolbar"
        }
        if item.action == #selector(actualSize(_:)) { item.title = "Actual Size" }   // text windows rename it
        if item.action == #selector(togglePageStrip(_:)) { item.title = pageStripVisible ? "Hide Page Thumbnails" : "Show Page Thumbnails" }
        return validate(item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }

    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(toggleMarkup(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(cropToSelection(_:)):
            return canEdit
        case #selector(copy(_:)):
            return document.state != nil
        case #selector(nextPage(_:)):
            return document.page + 1 < document.pageCount
        case #selector(previousPage(_:)):
            return document.page > 0
        case #selector(goToPage(_:)), #selector(togglePageStrip(_:)):
            return document.pageCount > 1
        case #selector(quickSave(_:)):
            return document.state != nil && (document.isDocumentEdited || document.fileURL == nil)
        default:
            return true
        }
    }

    // MARK: Inspector

    func inspectorRows() async -> [(String, String)] {
        var rows: [(String, String)] = []
        let info = document.info
        if let url = document.fileURL {
            rows.append(("File", url.lastPathComponent))
            rows.append(("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
        }
        rows.append(("Kind", info.typeIdentifier.flatMap { UTType($0)?.localizedDescription } ?? "Image"))
        rows.append(("Dimensions", "\(Int(info.pixelSize.width)) × \(Int(info.pixelSize.height)) pixels"))
        rows.append(info.pixelsPerPoint > 1
                    ? ("Scale", "@\(Int(info.pixelsPerPoint))x Retina (\(Int(info.dpi.width)) dpi)")
                    : ("Resolution", "\(Int(info.dpi.width.rounded())) dpi"))
        if let image = document.state?.image {
            let raw = (image.colorSpace?.name as String?)?.replacingOccurrences(of: "kCGColorSpace", with: "") ?? "Unknown"
            let names = ["SRGB": "sRGB", "DisplayP3": "Display P3", "ExtendedSRGB": "Extended sRGB", "LinearSRGB": "Linear sRGB",
                         "AdobeRGB1998": "Adobe RGB (1998)", "GenericGrayGamma2_2": "Gray", "ITUR_2020": "BT.2020", "ITUR_709": "BT.709"]
            let space = names[raw] ?? raw
            rows.append(("Color", space))
            let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            rows.append(("Depth", "\(image.bitsPerComponent) bits per channel\(alpha ? ", with alpha" : "")"))
        }
        if info.isAnimated { rows.append(("Frames", "\(info.frameCount)")) }
        if document.pageCount > 1 { rows.append(("Pages", "\(document.page + 1) of \(document.pageCount)")) }
        let tiff = info.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = info.properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String].compactMap { $0 }
        if !camera.isEmpty { rows.append(("Camera", camera.joined(separator: " "))) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { rows.append(("Lens", lens)) }
        var exposure: [String] = []
        if let t = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, t > 0 {
            exposure.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t))
        }
        if let f = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue { exposure.append(String(format: "f/%.1f", f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { exposure.append("ISO \(iso)") }
        if let mm = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue { exposure.append(String(format: "%.0f mm", mm)) }
        if !exposure.isEmpty { rows.append(("Exposure", exposure.joined(separator: "  "))) }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { rows.append(("Taken", date)) }
        if let n = document.state?.annotations.count, n > 0 { rows.append(("Markup", "\(n) mark\(n == 1 ? "" : "s")")) }
        return rows
    }
}
