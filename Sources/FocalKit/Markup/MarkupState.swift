import AppKit

/// Per-window markup choices (tool, color, size). Changes are broadcast so the bar and canvas stay in step.
@MainActor
final class MarkupState {
    static let didChange = Notification.Name("FocalMarkupStateDidChange")
    enum Property: String { case visible, tool, color, size }

    enum Tool: String, CaseIterable {
        case select, pen, highlighter, line, arrow, rectangle, ellipse, text, counter, redact, crop
        case underline, strikeout, note, signature   // PDF only

        /// The Markup bar for pictures and for PDFs (text markup, notes and signatures need a PDF's text and pages).
        static let imageTools: [Tool] = [.select, .pen, .highlighter, .line, .arrow, .rectangle, .ellipse, .text, .counter, .redact, .crop]
        static let pdfTools: [Tool] = [.select, .highlighter, .underline, .strikeout, .pen, .line, .arrow, .rectangle, .ellipse,
                                       .text, .note, .signature, .redact, .crop]

        var symbol: String {
            switch self {
            case .select: "hand.raised"
            case .pen: "scribble"
            case .highlighter: "highlighter"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .text: "textformat"
            case .counter: "1.circle"
            case .redact: "rectangle.fill"
            case .crop: "crop"
            case .underline: "underline"
            case .strikeout: "strikethrough"
            case .note: "note.text"
            case .signature: "signature"
            }
        }

        var label: String {
            switch self {
            case .select: "Move / Select"
            case .pen: "Pen"
            case .highlighter: "Highlighter"
            case .line: "Line"
            case .arrow: "Arrow"
            case .rectangle: "Rectangle"
            case .ellipse: "Oval"
            case .text: "Text"
            case .counter: "Number"
            case .redact: "Redact (solid box)"
            case .crop: "Crop"
            case .underline: "Underline"
            case .strikeout: "Strike Through"
            case .note: "Note"
            case .signature: "Signature"
            }
        }

        var shortcut: Character {
            switch self {
            case .select: "v"
            case .pen: "p"
            case .highlighter: "h"
            case .line: "l"
            case .arrow: "a"
            case .rectangle: "r"
            case .ellipse: "o"
            case .text: "t"
            case .counter: "n"
            case .redact: "x"
            case .crop: "c"
            case .underline: "u"
            case .strikeout: "s"
            case .note: "m"
            case .signature: "g"
            }
        }

        var kind: AnnotationKind? {
            switch self {
            case .pen: .pen
            case .highlighter: .highlighter
            case .line: .line
            case .arrow: .arrow
            case .rectangle: .rectangle
            case .ellipse: .ellipse
            case .text: .text
            case .counter: .counter
            case .redact: .redact
            case .select, .crop, .underline, .strikeout, .note, .signature: nil
            }
        }
    }

    /// Sizes are in screen points at the zoom you draw at, so a "medium" line looks medium on screen.
    enum Size: Int, CaseIterable {
        case small, medium, large, huge
        var stroke: CGFloat { [2, 4, 7, 12][rawValue] }
        var text: CGFloat { [14, 20, 28, 40][rawValue] }
        var label: String { ["Small", "Medium", "Large", "Extra large"][rawValue] }
    }

    /// Markup tools show when an image opens (Settings can turn that off).
    var isVisible = Prefs.showMarkupOnOpen { didSet { if oldValue != isVisible { post(.visible) } } }
    /// Every window starts on Move/Select, so dragging moves the image until a drawing tool is picked.
    var tool: Tool = .select { didSet { post(.tool) } }
    var color: RGBAColor {
        didSet {
            if let data = try? JSONEncoder().encode(color) { Prefs.set(String(decoding: data, as: UTF8.self), Prefs.Key.markupColor) }
            post(.color)
        }
    }
    var size: Size { didSet { Prefs.set(size.rawValue, Prefs.Key.markupSize); post(.size) } }

    init() {
        color = Prefs.string(Prefs.Key.markupColor)
            .flatMap { try? JSONDecoder().decode(RGBAColor.self, from: Data($0.utf8)) } ?? .red
        size = Size(rawValue: Prefs.integer(Prefs.Key.markupSize)) ?? .medium
    }

    private func post(_ property: Property) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["property": property.rawValue])
    }

    nonisolated static func property(of note: Notification) -> Property? {
        (note.userInfo?["property"] as? String).flatMap(Property.init)
    }
}
