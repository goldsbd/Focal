import AppKit

/// Your signature, drawn once with the trackpad or mouse and kept for signing PDFs. Stored as strokes in a box
/// one unit wide (so it scales cleanly), in this app's Application Support folder (release and dev builds apart).
@MainActor
enum SignatureStore {
    struct Signature: Codable, Equatable {
        /// Points with x in 0...1 and y in 0...aspect, y up (PDF page direction).
        var strokes: [[CGPoint]]
        var aspect: CGFloat
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ai.digitalzoo.focal").appendingPathComponent("signature.json")
    }

    static func load() -> Signature? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Signature.self, from: data)
    }

    static func save(_ signature: Signature) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(signature).write(to: fileURL, options: .atomic)
    }

    /// Strokes drawn in a view (y up) scaled into the unit-wide box; nil when nothing was drawn.
    nonisolated static func normalize(_ strokes: [[CGPoint]]) -> Signature? {
        let points = strokes.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX - minX > 2 else { return nil }
        let scale = 1 / (maxX - minX)
        return Signature(strokes: strokes.filter { !$0.isEmpty }.map { $0.map { CGPoint(x: ($0.x - minX) * scale, y: ($0.y - minY) * scale) } },
                         aspect: max((maxY - minY) * scale, 0.05))
    }

    /// A sheet to sign in. `completion(true)` once a signature is saved.
    static func capture(in window: NSWindow, completion: @escaping @MainActor (Bool) -> Void) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let pad = SignaturePad()
        let title = NSTextField(labelWithString: "Sign with the trackpad or mouse")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let clear = NSButton(title: "Clear", target: pad, action: #selector(SignaturePad.clear(_:)))
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        let done = NSButton(title: "Save Signature", target: nil, action: nil)
        done.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let handler = SheetHandler(window: window, sheet: sheet, pad: pad, completion: completion)
        cancel.target = handler
        cancel.action = #selector(SheetHandler.cancel(_:))
        done.target = handler
        done.action = #selector(SheetHandler.save(_:))
        objc_setAssociatedObject(sheet, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
        let buttons = NSStackView(views: [clear, NSView(), cancel, done])
        let stack = NSStackView(views: [title, pad, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.spacing = 10
        pad.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pad.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            pad.heightAnchor.constraint(equalToConstant: 190),
            buttons.widthAnchor.constraint(equalTo: pad.widthAnchor),
        ])
        sheet.contentView = stack
        window.beginSheet(sheet)
    }

    nonisolated(unsafe) private static var handlerKey = 0

    @MainActor private final class SheetHandler: NSObject {
        weak var window: NSWindow?
        let sheet: NSWindow
        let pad: SignaturePad
        let completion: @MainActor (Bool) -> Void

        init(window: NSWindow, sheet: NSWindow, pad: SignaturePad, completion: @escaping @MainActor (Bool) -> Void) {
            self.window = window
            self.sheet = sheet
            self.pad = pad
            self.completion = completion
        }

        @objc func cancel(_ sender: Any?) {
            window?.endSheet(sheet)
            completion(false)
        }

        @objc func save(_ sender: Any?) {
            guard let signature = SignatureStore.normalize(pad.strokes) else { NSSound.beep(); return }
            do {
                try SignatureStore.save(signature)
                window?.endSheet(sheet)
                completion(true)
            } catch {
                NSAlert(error: error).beginSheetModal(for: sheet)
            }
        }
    }
}

/// White card you draw your signature on.
final class SignaturePad: NSView {
    private(set) var strokes: [[CGPoint]] = []

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: 24, y: 48))
        baseline.line(to: NSPoint(x: bounds.width - 24, y: 48))
        baseline.stroke()
        NSColor.black.setStroke()
        for stroke in strokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            stroke.dropFirst().forEach { path.line(to: $0) }
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    @objc func clear(_ sender: Any?) {
        strokes = []
        needsDisplay = true
    }

    /// For the test driver: draw strokes as if signed.
    func setStrokes(_ new: [[CGPoint]]) {
        strokes = new
        needsDisplay = true
    }
}
