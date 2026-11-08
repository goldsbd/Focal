import AppKit

@MainActor
protocol CanvasViewDelegate: AnyObject {
    var canvasMagnification: CGFloat { get }
    func canvasRequestsNavigation(_ offset: Int)
    func canvasToggleZoom(at point: NSPoint)
}

/// The scroll view's document view: image + marks. Without Markup the mouse is a hand that pans;
/// with Markup it draws with the current tool (space-drag or middle-drag still pans).
final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let document: ImageDocument
    let markup: MarkupState
    weak var delegate: CanvasViewDelegate?

    private let imageView = ImageLayerView()
    private let overlay = AnnotationOverlayView()
    private(set) var selectedID: UUID? { didSet { overlay.needsDisplay = true } }
    private(set) var pendingCrop: CGRect?
    private var live: Annotation?
    private var dragged: Annotation?
    private var drag: Drag = .none
    private var spaceHeld = false
    private var trackingArea: NSTrackingArea?
    private var markupObserver: NSObjectProtocol?

    private var textField: NSTextField?
    private var textEdit: (original: Annotation?, origin: CGPoint, fontSize: CGFloat, color: RGBAColor)?

    private enum Drag {
        case none
        case panning(start: NSPoint, origin: NSPoint)
        case creating(start: CGPoint)
        case moving(start: CGPoint, original: Annotation)
        case resizing(handle: Int, original: Annotation)
        case cropping(start: CGPoint)
    }

    init(document: ImageDocument, markup: MarkupState) {
        self.document = document
        self.markup = markup
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true   // views don't clip by default since macOS 14; marks must stop at the image edge
        overlay.clipsToBounds = true
        for v in [imageView, overlay] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        overlay.canvas = self
        markupObserver = NotificationCenter.default.addObserver(forName: MarkupState.didChange, object: markup, queue: .main) { [weak self] note in
            let property = MarkupState.property(of: note)
            MainActor.assumeIsolated { self?.markupChanged(property) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let markupObserver { NotificationCenter.default.removeObserver(markupObserver) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Coordinates (image pixels, top-left origin ↔ canvas points)

    var pixelsPerPoint: CGFloat { document.info.pixelsPerPoint }
    var canvasRect: CGRect { document.state?.canvasRect ?? CGRect(origin: .zero, size: document.info.pixelSize) }
    var magnification: CGFloat { delegate?.canvasMagnification ?? 1 }
    /// Image pixels per on-screen point at the current zoom.
    private var pixelsPerScreenPoint: CGFloat { pixelsPerPoint / max(magnification, 0.01) }

    func imagePoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x * pixelsPerPoint + canvasRect.minX, y: p.y * pixelsPerPoint + canvasRect.minY)
    }

    func viewPoint(_ p: CGPoint) -> NSPoint {
        NSPoint(x: (p.x - canvasRect.minX) / pixelsPerPoint, y: (p.y - canvasRect.minY) / pixelsPerPoint)
    }

    func viewRect(_ r: CGRect) -> NSRect {
        let o = viewPoint(r.origin)
        return NSRect(x: o.x, y: o.y, width: r.width / pixelsPerPoint, height: r.height / pixelsPerPoint)
    }

    // MARK: Content

    func reload() {
        let size = canvasRect.size
        setFrameSize(NSSize(width: size.width / pixelsPerPoint, height: size.height / pixelsPerPoint))
        if let state = document.state {
            let visible = state.crop.flatMap { state.image.cropping(to: $0) } ?? state.image
            imageView.image = ImageOps.displayImage(visible)
        } else {
            imageView.image = nil
        }
        if let id = selectedID, document.state?.annotations.contains(where: { $0.id == id }) != true { selectedID = nil }
        overlay.needsDisplay = true
    }

    func showFrame(_ image: CGImage) { imageView.image = image }

    func annotationsChanged() {
        if let id = selectedID, document.state?.annotations.contains(where: { $0.id == id }) != true { selectedID = nil }
        overlay.needsDisplay = true
    }

    func magnificationChanged(_ m: CGFloat, backingScale: CGFloat) {
        imageView.nearestNeighbour = m * backingScale / pixelsPerPoint >= 2
        if selectedID != nil || pendingCrop != nil || textField != nil { overlay.needsDisplay = true }
    }

    var displayedAnnotations: [Annotation] {
        var list = document.state?.annotations ?? []
        if let d = dragged, let i = list.firstIndex(where: { $0.id == d.id }) { list[i] = d }
        if let editing = textEdit?.original?.id { list.removeAll { $0.id == editing } }
        if let live { list.append(live) }
        return list
    }

    var selectedAnnotation: Annotation? {
        guard let id = selectedID, textEdit?.original?.id != id else { return nil }
        return displayedAnnotations.first { $0.id == id }
    }

    var hasPendingCrop: Bool { pendingCrop.map { $0.width >= 1 && $0.height >= 1 } ?? false }

    // MARK: Cursor

    private var cursor: NSCursor {
        if case .panning = drag { return .closedHand }
        guard markup.isVisible, !spaceHeld else { return .openHand }
        switch markup.tool {
        case .select: return .openHand
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            trackingArea = area
        }
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    private func refreshCursor() {
        guard let window else { return }
        if visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { cursor.set() }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)   // ends any text editing (commits it)
        let vp = convert(event.locationInWindow, from: nil)
        guard markup.isVisible, document.state != nil, !spaceHeld else {
            if event.clickCount == 2 { delegate?.canvasToggleZoom(at: vp) } else { beginPan(event) }
            return
        }
        let p = imagePoint(vp)
        let tolerance = 6 * pixelsPerScreenPoint
        if markup.tool != .crop, let sel = selectedAnnotation, let h = handleIndex(at: p, of: sel, tolerance: tolerance) {
            drag = .resizing(handle: h, original: sel)
            return
        }
        switch markup.tool {
        case .select:
            if let hit = topAnnotation(at: p, tolerance: tolerance) {
                selectedID = hit.id
                if event.clickCount == 2, hit.kind == .text { beginTextEditing(existing: hit); return }
                drag = .moving(start: p, original: hit)
            } else {
                selectedID = nil
                beginPan(event)
            }
        case .text:
            if let hit = topAnnotation(at: p, tolerance: tolerance), hit.kind == .text {
                selectedID = hit.id
                beginTextEditing(existing: hit)
            } else {
                beginTextEditing(at: p)
            }
        case .crop:
            let start = clampToImage(p)
            pendingCrop = CGRect(origin: start, size: .zero)
            drag = .cropping(start: start)
        case .counter:
            let next = (document.state?.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
            live = Annotation(kind: .counter, points: [p], color: markup.color, lineWidth: 0,
                              fontSize: markup.size.text * pixelsPerScreenPoint, number: next)
            drag = .creating(start: p)
        default:
            guard let kind = markup.tool.kind else { return }
            let width = markup.size.stroke * (kind == .highlighter ? 4 : 1) * pixelsPerScreenPoint
            let color = kind == .redact ? RGBAColor.black : (kind == .highlighter && markup.color == .red ? RGBAColor(1, 0.85, 0) : markup.color)
            let points = kind == .pen || kind == .highlighter ? [p] : [p, p]
            live = Annotation(kind: kind, points: points, color: color, lineWidth: width)
            drag = .creating(start: p)
        }
        overlay.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .panning(let start, let origin):
            pan(from: start, origin: origin, to: event.locationInWindow)
            return
        case .creating(let start):
            guard var a = live else { return }
            switch a.kind {
            case .pen, .highlighter:
                if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) >= 0.75 * pixelsPerScreenPoint { a.points.append(p) }
            case .counter:
                a.points = [p]
            case .line, .arrow:
                a.points[1] = shift ? Geometry.constrain45(from: start, to: p) : p
            case .rectangle, .ellipse, .redact:
                a.points[1] = shift ? Geometry.constrainSquare(from: start, to: p) : p
            case .text:
                break
            }
            live = a
        case .moving(let start, let original):
            dragged = original.translated(by: CGVector(dx: p.x - start.x, dy: p.y - start.y))
        case .resizing(let handle, let original):
            var target = p
            if shift, let anchor = original.anchor(forHandle: handle) {
                target = original.kind == .line || original.kind == .arrow
                    ? Geometry.constrain45(from: anchor, to: p) : Geometry.constrainSquare(from: anchor, to: p)
            }
            dragged = original.movingHandle(handle, to: target)
        case .cropping(let start):
            let end = clampToImage(p)
            pendingCrop = Geometry.rect(start, end)
        }
        autoscroll(with: event)
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            overlay.needsDisplay = true
            refreshCursor()
        }
        switch drag {
        case .creating:
            guard let a = live else { return }
            live = nil
            if isMeaningful(a) {
                document.addAnnotation(a)
                selectedID = a.id
            }
        case .moving(_, let original), .resizing(_, let original):
            if let d = dragged, d != original { document.replaceAnnotation(d) }
            dragged = nil
        case .cropping:
            if let c = pendingCrop, c.width < 2 * pixelsPerScreenPoint || c.height < 2 * pixelsPerScreenPoint { pendingCrop = nil }
        case .panning, .none:
            break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        endEditing()
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
        }
        add("Save", #selector(ImageViewController.quickSave(_:)), "s")
        add("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add("Copy", #selector(ImageViewController.copy(_:)), "c")
        menu.addItem(.separator())
        add(markup.isVisible ? "Hide Markup Tools" : "Show Markup Tools", #selector(ImageViewController.toggleMarkup(_:)), "a", [.command, .shift])
        add("Rotate Left", #selector(ImageViewController.rotateLeft(_:)), "l")
        add("Rotate Right", #selector(ImageViewController.rotateRight(_:)), "r")
        add("Crop", #selector(ImageViewController.cropToSelection(_:)), "k")
        menu.addItem(.separator())
        add("Show in Finder", #selector(ViewerWindowController.showInFinder(_:)))
        add("Move to Trash", #selector(ViewerWindowController.moveToTrash(_:)), "\u{8}")
        return menu
    }

    // Middle button pans in every mode.
    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    private func beginPan(_ event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        drag = .panning(start: event.locationInWindow, origin: clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    private func pan(from start: NSPoint, origin: NSPoint, to current: NSPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let m = scroll.magnification
        // Window y grows upward, the document is flipped: dragging up reveals what is below.
        let target = NSPoint(x: origin.x - (current.x - start.x) / m, y: origin.y + (current.y - start.y) / m)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func topAnnotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        displayedAnnotations.last { $0.hitTest(p, tolerance: tolerance) }
    }

    private func handleIndex(at p: CGPoint, of a: Annotation, tolerance: CGFloat) -> Int? {
        a.handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= tolerance + 2 * pixelsPerScreenPoint }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let r = canvasRect
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func isMeaningful(_ a: Annotation) -> Bool {
        let minSize = 3 * pixelsPerScreenPoint
        switch a.kind {
        case .line, .arrow: return hypot(a.points[1].x - a.points[0].x, a.points[1].y - a.points[0].y) >= minSize
        case .rectangle, .ellipse, .redact: return a.rect.width >= minSize && a.rect.height >= minSize
        case .pen, .highlighter, .counter, .text: return true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53:   // Esc
            if cancelCurrent() { return }
        case 51, 117:   // Delete, Forward Delete
            if selectedID != nil { deleteSelection(); return }
        case 36, 76:   // Return, Enter
            if hasPendingCrop { applyCrop(); return }
        case 123, 124, 125, 126:   // arrows
            if markup.isVisible, let sel = selectedAnnotation {
                let step = (event.modifierFlags.contains(.shift) ? 10 : 1) * pixelsPerScreenPoint
                let d: CGVector = switch event.keyCode {
                case 123: CGVector(dx: -step, dy: 0)
                case 124: CGVector(dx: step, dy: 0)
                case 125: CGVector(dx: 0, dy: step)
                default: CGVector(dx: 0, dy: -step)
                }
                document.replaceAnnotation(sel.translated(by: d))
                return
            }
            if event.keyCode == 123 || event.keyCode == 126 { delegate?.canvasRequestsNavigation(-1); return }
            delegate?.canvasRequestsNavigation(1)
            return
        case 49:   // Space: hold to pan
            if !event.isARepeat { spaceHeld = true; refreshCursor() }
            return
        default:
            break
        }
        if markup.isVisible, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = MarkupState.Tool.imageTools.first(where: { $0.shortcut == ch }) {
            markup.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            refreshCursor()
        } else {
            super.keyUp(with: event)
        }
    }

    /// Esc: cancel a crop, then drop the selection. Returns false when there was nothing to cancel
    /// so Esc can still leave full screen.
    private func cancelCurrent() -> Bool {
        if pendingCrop != nil { pendingCrop = nil; overlay.needsDisplay = true; return true }
        if selectedID != nil { selectedID = nil; return true }
        return false
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    private func deleteSelection() {
        guard let id = selectedID else { return }
        selectedID = nil
        document.removeAnnotation(id: id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(delete(_:)) { return selectedID != nil }
        return true
    }

    func applyCrop() {
        guard let c = pendingCrop, hasPendingCrop else { return }
        pendingCrop = nil
        selectedID = nil
        document.crop(to: c)
        markup.tool = .select
    }

    // MARK: Markup state

    private func markupChanged(_ property: MarkupState.Property?) {
        switch property {
        case .visible:
            if !markup.isVisible { endEditing(); pendingCrop = nil; selectedID = nil }
        case .tool:
            if markup.tool != .crop { pendingCrop = nil }
            if markup.tool != .text { endEditing() }
        case .color:
            if let field = textField { field.textColor = markup.color.nsColor; textEdit?.color = markup.color }
            if var sel = selectedAnnotation, sel.color != markup.color {
                sel.color = markup.color
                document.replaceAnnotation(sel)
            }
        case .size:
            if let field = textField, let edit = textEdit {
                let size = markup.size.text * pixelsPerScreenPoint
                textEdit?.fontSize = size
                field.font = Annotation.font(size: size / pixelsPerPoint)
                field.sizeToFit()
                _ = edit
            }
            if var sel = selectedAnnotation {
                switch sel.kind {
                case .text, .counter: sel.fontSize = markup.size.text * pixelsPerScreenPoint
                case .highlighter: sel.lineWidth = markup.size.stroke * 4 * pixelsPerScreenPoint
                case .redact: break
                default: sel.lineWidth = markup.size.stroke * pixelsPerScreenPoint
                }
                document.replaceAnnotation(sel)
            }
        case .none:
            break
        }
        overlay.needsDisplay = true
        refreshCursor()
    }

    // MARK: Text

    private func beginTextEditing(at p: CGPoint) {
        startTextField(text: "", origin: p, fontSize: markup.size.text * pixelsPerScreenPoint, color: markup.color, original: nil)
    }

    private func beginTextEditing(existing a: Annotation) {
        startTextField(text: a.text, origin: a.points.first ?? .zero, fontSize: a.fontSize, color: a.color, original: a)
    }

    private func startTextField(text: String, origin: CGPoint, fontSize: CGFloat, color: RGBAColor, original: Annotation?) {
        endEditing()
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Annotation.font(size: fontSize / pixelsPerPoint)
        field.textColor = color.nsColor
        field.delegate = self
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        textEdit = (original, origin, fontSize, color)
        textField = field
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
        overlay.needsDisplay = true
    }

    private func layoutTextField() {
        guard let field = textField, let edit = textEdit else { return }
        field.sizeToFit()
        let inset: CGFloat = 2   // NSTextField's text inset, so typed text lines up with the drawn text
        let origin = viewPoint(edit.origin)
        field.frame = NSRect(x: origin.x - inset, y: origin.y, width: max(field.frame.width + 12, 40), height: field.frame.height)
    }

    func controlTextDidChange(_ obj: Notification) { layoutTextField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endEditing(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endEditing(commit: false); return true }
        return false   // ⌥Return inserts a line break (insertNewlineIgnoringFieldEditor)
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing() }

    func endEditing(commit: Bool = true) {
        guard let field = textField, let edit = textEdit else { return }
        textField = nil   // re-entrancy: removing the field ends editing again
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textEdit = nil
        if commit {
            if var original = edit.original {
                if text.isEmpty {
                    document.removeAnnotation(id: original.id)
                } else if text != original.text || edit.color != original.color || edit.fontSize != original.fontSize {
                    original.text = text
                    original.color = edit.color
                    original.fontSize = edit.fontSize
                    document.replaceAnnotation(original)
                }
            } else if !text.isEmpty {
                let a = Annotation(kind: .text, points: [edit.origin], color: edit.color, lineWidth: 0, text: text, fontSize: edit.fontSize)
                document.addAnnotation(a)
                selectedID = a.id
            }
        }
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(self) }
        overlay.needsDisplay = true
    }
}
