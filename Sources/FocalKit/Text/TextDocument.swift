import AppKit
import UniformTypeIdentifiers

/// A text file, viewable and editable: plain text and Markdown (saved in the encoding, BOM and line endings
/// they were opened with) or rich text, RTF/RTFD (saved with their fonts, styles and page settings).
@objc(TextDocument)
final class TextDocument: NSDocument {
    /// The text itself. The window's layout manager attaches to this storage, so saving reads exactly what's
    /// on screen and Revert to Saved updates the open window in place.
    let storage = NSTextStorage()
    private(set) var encodingName = String.localizedName(of: .utf8)   // a new file is UTF-8
    private(set) var encoding: String.Encoding = .utf8
    private(set) var hasBOM = false
    private(set) var lineEnding: LineEnding = .lf
    private(set) var lineCount = 0
    private(set) var longestLine = 0
    /// Set when the last save couldn't use the file's encoding and wrote UTF-8 instead (for the confirmation).
    private(set) var lastSaveSwitchedEncoding = false
    /// Page size, margins, background colour etc. read from an RTF, written back on save.
    private var richAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]

    var text: String { storage.string }
    /// Follows the file: an untitled text saved as "notes.md" becomes Markdown.
    var format: TextFormat { TextFormat(typeName: fileType, url: fileURL) }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(ViewerWindowController())
    }

    /// Rich text is read by AppKit straight from the URL (RTFD is a folder); plain text goes on to read(from:Data).
    override func read(from url: URL, ofType typeName: String) throws {
        guard let type = UTType(typeName), TextFormat.isRich(type) else {
            try super.read(from: url, ofType: typeName)
            return
        }
        try MainActor.assumeIsolated {
            var attributes: NSDictionary?
            let rich = try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
            richAttributes = (attributes as? [NSAttributedString.DocumentAttributeKey: Any]) ?? [:]
            storage.setAttributedString(rich)
            encodingName = TextFormat.isRichPackage(typeName) ? "Rich Text with Attachments (RTFD)" : "Rich Text (RTF)"
            lineCount = TextDecoding.lineCount(rich.string)
            Log.event("rich text \(url.lastPathComponent) \(rich.length) characters")
        }
    }

    /// Runs on the main thread (this class never opts into concurrent reading); see ImageDocument.read.
    override func read(from data: Data, ofType typeName: String) throws {
        MainActor.assumeIsolated {
            let decoded = TextDecoding.decode(data)
            encodingName = decoded.encodingName
            encoding = decoded.encoding
            hasBOM = decoded.hasBOM
            lineEnding = decoded.lineEnding
            (lineCount, longestLine) = TextDecoding.measure(decoded.text)
            // On Revert the view is attached: keep its font rather than dropping to the 12 pt default.
            let style = storage.length > 0 ? storage.attributes(at: 0, effectiveRange: nil) : [:]
            storage.setAttributedString(NSAttributedString(string: decoded.text, attributes: style))
            Log.event("text \(fileURL?.lastPathComponent ?? "") \(data.count) bytes, \(lineCount) lines, \(lineEnding.rawValue)")
        }
    }

    /// Saving runs on the main thread too (canAsynchronouslyWrite is off). RTFD is a folder, so it is written
    /// as a file wrapper; everything else goes through data(ofType:).
    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        guard TextFormat.isRichPackage(typeName) else { return try super.fileWrapper(ofType: typeName) }
        var wrapper: FileWrapper?   // FileWrapper isn't Sendable, so it can't be returned out of assumeIsolated
        try MainActor.assumeIsolated {
            storage.layoutManagers.first?.firstTextView?.breakUndoCoalescing()
            wrapper = try storage.fileWrapper(from: NSRange(location: 0, length: storage.length),
                                              documentAttributes: richDocumentAttributes(.rtfd))
        }
        guard let wrapper else { throw CocoaError(.fileWriteUnknown) }
        return wrapper
    }

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            // Without this, typing straight after a save merges into the pre-save undo step: the document
            // wouldn't be marked edited and one Undo would cross the save.
            storage.layoutManagers.first?.firstTextView?.breakUndoCoalescing()
            if let type = UTType(typeName), TextFormat.isRich(type) {
                return try storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: richDocumentAttributes(.rtf))
            }
            let encoded = TextDecoding.encode(storage.string, encoding: encoding, bom: hasBOM, lineEnding: lineEnding)
            lastSaveSwitchedEncoding = encoded.fellBackToUTF8
            if encoded.fellBackToUTF8 {
                Log.event("text save: \(encodingName) can't hold the text, writing UTF-8")
                encoding = .utf8
                hasBOM = false
                encodingName = String.localizedName(of: .utf8)
            }
            return encoded.data
        }
    }

    private func richDocumentAttributes(_ type: NSAttributedString.DocumentType) -> [NSAttributedString.DocumentAttributeKey: Any] {
        var attributes = richAttributes
        attributes[.documentType] = type
        return attributes
    }

    /// Save As offers formats of the same family only: rich text stays rich (RTF ↔ RTFD), plain stays plain
    /// (text ↔ Markdown, or its own type such as a Python script), so the window never has to change editors.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        MainActor.assumeIsolated {
            if format == .rich { return [UTType.rtf.identifier, UTType.rtfd.identifier] }
            var types = [UTType.plainText.identifier, TextFormat.markdownType]
            if let fileType, !types.contains(fileType) { types.insert(fileType, at: 0) }
            return types
        }
    }

    /// Text has no print layout here (Preview doesn't print text either): Print… stays off rather than failing.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(printDocument(_:)) ? false : super.validateUserInterfaceItem(item)
    }

    /// Any extension goes: "notes.md", "todo.txt", "server.log". The format menu sets the default one.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        return true
    }

    /// Line count after edits (UTF-16 scan, cheap enough to run shortly after typing stops).
    func recount() {
        lineCount = TextDecoding.lineCount(storage.string)
    }
}
