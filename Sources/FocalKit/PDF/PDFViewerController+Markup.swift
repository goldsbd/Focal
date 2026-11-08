import AppKit
import PDFKit

extension MarkupState.Tool {
    /// Tools that mark text PDFKit has selected rather than drawing.
    var marksText: Bool { self == .highlighter || self == .underline || self == .strikeout }
}

/// A drag in progress, in page coordinates.
struct PDFInteraction {
    enum Kind { case none, stroke([CGPoint]), shape(start: CGPoint, end: CGPoint), moving(start: CGPoint, original: CGRect) }
    var kind: Kind = .none
    var page: PDFPage?
}

/// Draws marks in progress, the selected mark and the crop area over the PDF. It takes the mouse only while a
/// drawing tool is picked or a mark is under the pointer, so text selection, links and form fields still work.
final class PDFOverlayView: NSView {
    weak var controller: PDFViewerController?

    override var isFlipped: Bool { superview?.isFlipped ?? false }   // same coordinates as the PDF view

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller, !isHidden, frame.contains(point) else { return nil }
        if let inner = super.hitTest(point), inner !== self { return inner }   // the text box being typed in
        return controller.overlayTakesMouse(at: convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.markupMouse(.down, event) }
    override func mouseDragged(with event: NSEvent) { controller?.markupMouse(.dragged, event) }
    override func mouseUp(with event: NSEvent) { controller?.markupMouse(.up, event) }
    override func scrollWheel(with event: NSEvent) {
        controller?.pdfView.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }
    override func resetCursorRects() {
        if let tool = controller?.activeTool, tool != .select, !tool.marksText { addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair) }
    }
    override func draw(_ dirtyRect: NSRect) { controller?.drawOverlay() }
}

/// The box you type a text mark into; Return finishes, Esc cancels, clicking elsewhere finishes.
final class PDFTextEditor: NSTextField, NSTextFieldDelegate {
    let page: PDFPage
    let topLeft: CGPoint          // page coordinates
    let pointSize: CGFloat        // page points
    let existing: PDFAnnotation?
    var onFinish: ((Bool) -> Void)?
    private var finished = false

    init(page: PDFPage, topLeft: CGPoint, pointSize: CGFloat, existing: PDFAnnotation?) {
        self.page = page
        self.topLeft = topLeft
        self.pointSize = pointSize
        self.existing = existing
        super.init(frame: .zero)
        delegate = self
        isBordered = true
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        usesSingleLineMode = false
        cell?.wraps = true
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): finish(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)): finish(commit: false); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(commit: true) }

    func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        onFinish?(commit)
    }
}

/// Building PDF marks from what was drawn (page coordinates; PDFKit wants paths and points relative to bounds).
enum PDFMarks {
    static func isMarkup(_ a: PDFAnnotation) -> Bool {
        !["Widget", "Link", "Popup"].contains(a.type ?? "")
    }

    private static func border(_ width: CGFloat) -> PDFBorder {
        let b = PDFBorder()
        b.lineWidth = width
        return b
    }

    private static func box(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    static func ink(_ strokes: [[CGPoint]], color: NSColor, width: CGFloat) -> PDFAnnotation {
        let bounds = box(strokes.flatMap { $0 }).insetBy(dx: -width, dy: -width)
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: stroke[0].x - bounds.minX, y: stroke[0].y - bounds.minY))
            for p in stroke.dropFirst() { path.line(to: NSPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
            if stroke.count == 1 { path.line(to: NSPoint(x: stroke[0].x - bounds.minX + 0.1, y: stroke[0].y - bounds.minY)) }
            a.add(path)
        }
        a.color = color
        a.border = border(width)
        return a
    }

    static func line(from start: CGPoint, to end: CGPoint, arrow: Bool, color: NSColor, width: CGFloat) -> PDFAnnotation {
        let bounds = box([start, end]).insetBy(dx: -max(width * 4, 8), dy: -max(width * 4, 8))
        let a = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        a.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        a.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        a.endLineStyle = arrow ? .openArrow : .none
        a.color = color
        a.border = border(width)
        return a
    }

    static func shape(_ rect: CGRect, oval: Bool, color: NSColor, width: CGFloat) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect.insetBy(dx: -width / 2, dy: -width / 2), forType: oval ? .circle : .square, withProperties: nil)
        a.color = color
        a.border = border(width)
        return a
    }

    static func redaction(_ rect: CGRect) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = .black
        a.interiorColor = .black
        a.border = border(0)
        return a
    }

    /// One line of selected text: the highlight (or underline, strike-through) covers exactly that line.
    static func textMarkup(_ line: PDFSelection, on page: PDFPage, type: PDFAnnotationSubtype, color: NSColor) -> PDFAnnotation? {
        let b = line.bounds(for: page)
        guard b.width > 0, b.height > 0 else { return nil }
        let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
        a.quadrilateralPoints = [NSPoint(x: 0, y: b.height), NSPoint(x: b.width, y: b.height), .zero, NSPoint(x: b.width, y: 0)].map { NSValue(point: $0) }
        a.color = color
        return a
    }

    static func freeTextBounds(_ text: String, topLeft: CGPoint, pointSize: CGFloat) -> CGRect {
        let font = NSFont.systemFont(ofSize: pointSize)
        let size = (text.isEmpty ? " " : text as NSString).boundingRect(with: NSSize(width: 10_000, height: 10_000),
                                                                        options: [.usesLineFragmentOrigin], attributes: [.font: font]).size
        let w = ceil(size.width) + 10, h = ceil(size.height) + 6
        return CGRect(x: topLeft.x, y: topLeft.y - h, width: w, height: h)
    }

    static func freeText(_ text: String, topLeft: CGPoint, pointSize: CGFloat, color: NSColor) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: freeTextBounds(text, topLeft: topLeft, pointSize: pointSize), forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = .systemFont(ofSize: pointSize)
        a.fontColor = color
        a.color = .clear
        a.border = border(0)
        a.alignment = .left
        return a
    }

    static func note(_ text: String, at p: CGPoint) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
        a.contents = text
        a.iconType = .note
        a.color = .systemYellow
        return a
    }
}

extension PDFViewerController {
    /// What the mouse does now: the picked tool while the Markup bar shows, otherwise select (text, marks).
    var activeTool: MarkupState.Tool { markup.isVisible && document.canAnnotate ? markup.tool : .select }

    func toolChanged() {
        overlay.window?.invalidateCursorRects(for: overlay)
        if markup.tool != .crop { pendingCrop = nil }
        if activeTool.marksText { markSelectedText() }   // text already selected: picking the tool marks it
        overlay.needsDisplay = true
    }

    @objc func toggleMarkup(_ sender: Any?) {
        guard document.canAnnotate else { NSSound.beep(); return }
        markup.isVisible.toggle()
    }

    /// The topmost mark (not a form field or link) under a point in the view.
    func markHit(at point: NSPoint) -> (annotation: PDFAnnotation, page: PDFPage)? {
        guard let page = pdfView.page(for: point, nearest: false) else { return nil }
        let p = pdfView.convert(point, to: page)
        let tolerance = 4 / max(pdfView.scaleFactor, 0.01)
        guard let hit = page.annotations.reversed().first(where: { PDFMarks.isMarkup($0) && $0.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) })
        else { return nil }
        return (hit, page)
    }

    func overlayTakesMouse(at point: NSPoint) -> Bool {
        guard !document.pdf.isLocked else { return false }
        let tool = activeTool
        if tool.marksText { return false }
        if tool == .select { return markHit(at: point) != nil }
        return pdfView.page(for: point, nearest: false) != nil
    }

    enum MousePhase { case down, dragged, up }

    func markupMouse(_ phase: MousePhase, _ event: NSEvent) {
        let p = pdfView.convert(event.locationInWindow, from: nil)
        switch phase {
        case .down:
            view.window?.makeFirstResponder(pdfView)   // finishes any text being typed
            guard let page = pdfView.page(for: p, nearest: true) else { return }
            let pp = pdfView.convert(p, to: page)
            interaction = PDFInteraction(kind: .none, page: page)
            let hit = markHit(at: p)
            switch activeTool {
            case .select:
                selectedMark = hit
                guard let hit else { return }
                if event.clickCount == 2 { edit(hit); return }
                interaction.kind = .moving(start: pp, original: hit.annotation.bounds)
            case .pen:
                interaction.kind = .stroke([pp])
            case .line, .arrow, .rectangle, .ellipse, .redact, .crop:
                interaction.kind = .shape(start: pp, end: pp)
            case .text:
                if let hit, hit.annotation.type == "FreeText" { edit(hit) } else { beginTextEditing(on: page, at: pp, existing: nil) }
            case .note:
                if let hit, hit.annotation.type == "Text" { edit(hit) } else { addNote(on: page, at: pp) }
            case .signature:
                placeSignature(on: page, at: pp)
            default:
                break
            }
        case .dragged:
            guard let page = interaction.page else { return }
            let pp = pdfView.convert(p, to: page)
            switch interaction.kind {
            case .stroke(let points):
                interaction.kind = .stroke(points + [pp])
            case .shape(let start, _):
                interaction.kind = .shape(start: start, end: event.modifierFlags.contains(.shift) ? constrained(start, pp) : pp)
            case .moving(let start, let original):
                selectedMark?.annotation.bounds = original.offsetBy(dx: pp.x - start.x, dy: pp.y - start.y)
                pdfView.annotationsChanged(on: page)
            case .none:
                break
            }
            overlay.needsDisplay = true
        case .up:
            finishDrag()
            overlay.needsDisplay = true
        }
    }

    /// Shift: lines snap to 45°, boxes become squares.
    private func constrained(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if activeTool == .line || activeTool == .arrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    /// Stroke width in page points for the chosen size (sizes are screen points at the zoom you draw at).
    private var strokeWidth: CGFloat { markup.size.stroke / max(pdfView.scaleFactor, 0.01) }

    private func finishDrag() {
        defer { interaction = PDFInteraction() }
        guard let page = interaction.page else { return }
        let color = markup.color.nsColor
        switch interaction.kind {
        case .stroke(let points):
            guard points.count > 1 else { return }
            document.add(PDFMarks.ink([points], color: color, width: strokeWidth), to: page, name: "Add Pen")
        case .shape(let start, let end):
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard hypot(rect.width, rect.height) > 3 else { return }
            switch activeTool {
            case .line, .arrow:
                document.add(PDFMarks.line(from: start, to: end, arrow: activeTool == .arrow, color: color, width: strokeWidth), to: page,
                             name: activeTool == .arrow ? "Add Arrow" : "Add Line")
            case .rectangle, .ellipse:
                document.add(PDFMarks.shape(rect, oval: activeTool == .ellipse, color: color, width: strokeWidth), to: page,
                             name: activeTool == .ellipse ? "Add Oval" : "Add Rectangle")
            case .redact:
                document.add(PDFMarks.redaction(rect), to: page, name: "Add Redaction", redaction: true)
            case .crop:
                pendingCrop = (page, rect.intersection(page.bounds(for: .cropBox)))
            default:
                break
            }
        case .moving(_, let original):
            if let mark = selectedMark { document.moved(mark.annotation, on: mark.page, from: original) }
        case .none:
            break
        }
    }

    // MARK: Text marks

    func markSelectedText() {
        guard document.canAnnotate, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty else { return }
        let tool = activeTool
        let type: PDFAnnotationSubtype = tool == .underline ? .underline : tool == .strikeout ? .strikeOut : .highlight
        let name = tool == .underline ? "Underline" : tool == .strikeout ? "Strike Through" : "Highlight"
        var color = markup.color.nsColor
        if type == .highlight, markup.color == RGBAColor.palette.first?.color { color = .systemYellow }   // red highlights read badly
        for line in selection.selectionsByLine() {
            for page in line.pages {
                if let mark = PDFMarks.textMarkup(line, on: page, type: type, color: color) { document.add(mark, to: page, name: name) }
            }
        }
        pdfView.clearSelection()
    }

    // MARK: Text boxes and notes

    func edit(_ mark: (annotation: PDFAnnotation, page: PDFPage)) {
        switch mark.annotation.type {
        case "FreeText":
            let b = mark.annotation.bounds
            beginTextEditing(on: mark.page, at: CGPoint(x: b.minX, y: b.maxY), existing: mark.annotation)
        case "Text":
            editNote(mark.annotation, on: mark.page)
        default:
            break
        }
    }

    func beginTextEditing(on page: PDFPage, at topLeft: CGPoint, existing: PDFAnnotation?) {
        endTextEditing(commit: true)
        let size = existing?.font?.pointSize ?? markup.size.text / max(pdfView.scaleFactor, 0.01)
        let editor = PDFTextEditor(page: page, topLeft: topLeft, pointSize: size, existing: existing)
        editor.stringValue = existing?.contents ?? ""
        editor.font = .systemFont(ofSize: size * pdfView.scaleFactor)
        editor.textColor = existing?.fontColor ?? markup.color.nsColor
        editor.onFinish = { [weak self] commit in self?.endTextEditing(commit: commit) }
        if let existing { existing.shouldDisplay = false; pdfView.annotationsChanged(on: page) }
        textEditor = editor
        overlay.addSubview(editor)
        positionTextEditor(editor)
        view.window?.makeFirstResponder(editor)
    }

    func positionTextEditor(_ editor: PDFTextEditor) {
        let text = editor.stringValue.isEmpty ? "Type here" : editor.stringValue
        let rect = PDFMarks.freeTextBounds(text, topLeft: editor.topLeft, pointSize: editor.pointSize)
        var frame = pdfView.convert(rect, from: editor.page)
        frame.size.width = max(frame.width + 40, 160)
        frame.size.height = max(frame.height + 6, 24)
        if !overlay.isFlipped { frame.origin.y = pdfView.convert(editor.topLeft, from: editor.page).y - frame.height }
        editor.frame = frame
    }

    func endTextEditing(commit: Bool) {
        guard let editor = textEditor else { return }
        textEditor = nil
        editor.finish(commit: commit)
        let text = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        if let existing = editor.existing {
            existing.shouldDisplay = true
            if commit, text.isEmpty {
                document.remove(existing, from: editor.page)
            } else if commit, text != existing.contents {
                let b = existing.bounds
                document.setText(text, bounds: PDFMarks.freeTextBounds(text, topLeft: CGPoint(x: b.minX, y: b.maxY), pointSize: editor.pointSize),
                                 of: existing, on: editor.page)
            }
            pdfView.annotationsChanged(on: editor.page)
        } else if commit, !text.isEmpty {
            document.add(PDFMarks.freeText(text, topLeft: editor.topLeft, pointSize: editor.pointSize, color: markup.color.nsColor),
                         to: editor.page, name: "Add Text")
        }
        view.window?.makeFirstResponder(pdfView)
    }

    private func addNote(on page: PDFPage, at point: CGPoint) {
        askForNote(text: "", existing: false) { [weak self] text, _ in
            guard let self, let text, !text.isEmpty else { return }
            self.document.add(PDFMarks.note(text, at: point), to: page, name: "Add Note")
        }
    }

    private func editNote(_ note: PDFAnnotation, on page: PDFPage) {
        askForNote(text: note.contents ?? "", existing: true) { [weak self] text, delete in
            guard let self else { return }
            if delete { self.document.remove(note, from: page, name: "Delete Note"); return }
            if let text, text != note.contents { self.document.setText(text, bounds: note.bounds, of: note, on: page, name: "Edit Note") }
        }
    }

    private func askForNote(text: String, existing: Bool, completion: @escaping @MainActor (String?, Bool) -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = existing ? "Note" : "Add a Note"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as? NSTextView
        textView?.string = text
        textView?.font = .systemFont(ofSize: 13)
        alert.accessoryView = scroll
        alert.addButton(withTitle: existing ? "Save" : "Add")
        alert.addButton(withTitle: "Cancel")
        if existing { alert.addButton(withTitle: "Delete Note") }
        alert.window.initialFirstResponder = textView
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: completion(textView?.string.trimmingCharacters(in: .whitespacesAndNewlines), false)
                case .alertThirdButtonReturn: completion(nil, true)
                default: completion(nil, false)
                }
            }
        }
    }

    // MARK: Signatures

    private func placeSignature(on page: PDFPage, at point: CGPoint) {
        guard let signature = SignatureStore.load() else {
            createSignature(nil)
            return
        }
        let width: CGFloat = 160
        let strokes = signature.strokes.map { $0.map { CGPoint(x: point.x + ($0.x - 0.5) * width, y: point.y + ($0.y - signature.aspect / 2) * width) } }
        document.add(PDFMarks.ink(strokes, color: .black, width: 1.6), to: page, name: "Add Signature")
    }

    /// Tools ▸ Create Signature…: sign with the trackpad or mouse; the signature is kept for next time.
    @objc func createSignature(_ sender: Any?) {
        guard let window = view.window else { return }
        SignatureStore.capture(in: window) { [weak self] saved in
            if saved, let self {
                self.markup.isVisible = true
                self.markup.tool = .signature
                Toast.show("Signature saved: click where it goes", in: self.view)
            }
        }
    }

    // MARK: Crop, delete, cancel

    @objc func cropToSelection(_ sender: Any?) {
        if let crop = pendingCrop, crop.rect.width > 2, crop.rect.height > 2 {
            document.crop(crop.page, to: crop.rect)
            pendingCrop = nil
        } else {
            markup.isVisible = true
            markup.tool = .crop
        }
    }

    override func insertNewline(_ sender: Any?) {
        if pendingCrop != nil { cropToSelection(sender) } else { super.insertNewline(sender) }
    }

    override func deleteBackward(_ sender: Any?) { deleteSelectedMark() }
    @objc func delete(_ sender: Any?) { deleteSelectedMark() }

    private func deleteSelectedMark() {
        guard let mark = selectedMark else { NSSound.beep(); return }
        selectedMark = nil
        document.remove(mark.annotation, from: mark.page)
    }

    override func cancelOperation(_ sender: Any?) {
        if pendingCrop != nil { pendingCrop = nil } else if selectedMark != nil { selectedMark = nil } else { super.cancelOperation(sender) }
    }

    // MARK: Drawing

    func drawOverlay() {
        let color = markup.color.nsColor
        let width = markup.size.stroke
        if let page = interaction.page {
            func v(_ p: CGPoint) -> NSPoint { pdfView.convert(p, from: page) }
            switch interaction.kind {
            case .stroke(let points) where points.count > 1:
                let path = NSBezierPath()
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: v(points[0]))
                points.dropFirst().forEach { path.line(to: v($0)) }
                color.setStroke()
                path.stroke()
            case .shape(let start, let end):
                let a = v(start), b = v(end)
                let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                switch activeTool {
                case .line, .arrow:
                    let path = NSBezierPath()
                    path.move(to: a)
                    path.line(to: b)
                    path.lineWidth = width
                    color.setStroke()
                    path.stroke()
                case .ellipse:
                    let path = NSBezierPath(ovalIn: rect)
                    path.lineWidth = width
                    color.setStroke()
                    path.stroke()
                case .redact:
                    NSColor.black.setFill()
                    rect.fill()
                case .crop:
                    dashed(rect)
                default:
                    let path = NSBezierPath(rect: rect)
                    path.lineWidth = width
                    color.setStroke()
                    path.stroke()
                }
            default:
                break
            }
        }
        if let crop = pendingCrop { dashed(pdfView.convert(crop.rect, from: crop.page)) }
        if let mark = selectedMark {
            let rect = pdfView.convert(mark.annotation.bounds, from: mark.page).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func dashed(_ rect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
