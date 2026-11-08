import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A PDF, or a PDF-compatible Illustrator file (read-only: saving through PDFKit would drop the Illustrator data).
/// PDFKit holds the pages. Every change (a mark, page order, rotation, crop) goes through here as one undo step,
/// which is also what marks the file edited.
@objc(PDFFileDocument)
final class PDFFileDocument: NSDocument {
    enum Change { case pages, annotations(PDFPage), unlocked }

    private(set) var pdf = PDFDocument()
    /// The password that unlocked it, so the saved file is encrypted the same way.
    private(set) var password: String?
    /// The page showing (the viewer keeps it current): exporting as a picture writes this page.
    var currentPageIndex = 0
    var onChange: ((Change) -> Void)?
    /// Bumped whenever a page looks different, so its thumbnail is redrawn.
    private(set) var pageVersions: [ObjectIdentifier: Int] = [:]
    /// Solid boxes that must take the text under them away: those pages are flattened to pictures when saved.
    private var redactions: Set<ObjectIdentifier> = []

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(ViewerWindowController())
    }

    var isPDFType: Bool { fileType.flatMap(UTType.init)?.conforms(to: .pdf) ?? true }
    var canAnnotate: Bool { isPDFType && !pdf.isLocked && pdf.allowsCommenting }
    var canEditPages: Bool { isPDFType && !pdf.isLocked && pdf.allowsDocumentAssembly }

    // MARK: Reading

    override func read(from url: URL, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            guard let doc = PDFDocument(url: url) else {
                let isAI = UTType(typeName)?.conforms(to: .pdf) == false
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                    NSLocalizedDescriptionKey: isAI
                        ? "“\(url.lastPathComponent)” was saved without PDF content, so it can't be shown."
                        : "“\(url.lastPathComponent)” isn't a PDF Focal can read.",
                ])
            }
            pdf = doc
            password = nil
            pageVersions = [:]
            redactions = []
            Log.event("pdf \(url.lastPathComponent) \(doc.pageCount) pages\(doc.isLocked ? ", locked" : "")")
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        undoManager?.removeAllActions()
        onChange?(.pages)
    }

    func unlock(with password: String) -> Bool {
        guard pdf.unlock(withPassword: password) else { return false }
        self.password = password
        onChange?(.unlocked)
        return true
    }

    // MARK: Saving

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        let pdfType = UTType.pdf.identifier
        guard saveOperation == .saveToOperation else { return [pdfType] }
        // Export also writes the page showing as a picture.
        return [pdfType, UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.tiff.identifier]
    }

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated {
            guard let type = UTType(typeName) else { throw ImageExporterError.unsupportedType(typeName) }
            if type.conforms(to: .pdf) { return try pdfData() }
            guard let page = pdf.page(at: currentPageIndex), let image = Self.render(page, scale: 2) else {
                throw ImageExporterError.encodeFailed
            }
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let flat = type.conforms(to: .jpeg) ? Flattener.flatten(EditState(image: image), background: white) ?? image : image
            return try ImageExporter.encode(flat, as: type, dpi: CGSize(width: 144, height: 144), sourceProperties: [:])
        }
    }

    private func pdfData() throws -> Data {
        var options: [AnyHashable: Any] = [:]
        if let password {   // keep it locked with the password it was opened with
            options[PDFDocumentWriteOption.ownerPasswordOption] = password
            options[PDFDocumentWriteOption.userPasswordOption] = password
        }
        guard let data = (try redactedCopy() ?? pdf).dataRepresentation(options: options) else {
            throw ImageExporterError.encodeFailed
        }
        return data
    }

    /// Pages with a redaction box become pictures of themselves (marks drawn in), so the text under the box is
    /// gone from the saved file, not just hidden. The open document is left as it is.
    private func redactedCopy() throws -> PDFDocument? {
        var flatten: [Int: PDFPage] = [:]
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i),
                  page.annotations.contains(where: { redactions.contains(ObjectIdentifier($0)) }) else { continue }
            guard let image = Self.render(page, scale: 3) else { throw ImageExporterError.encodeFailed }
            let ns = NSImage(cgImage: image, size: page.bounds(for: .cropBox).applying(rotation(page)).size)
            guard let flat = PDFPage(image: ns) else { throw ImageExporterError.encodeFailed }
            flatten[i] = flat
        }
        guard !flatten.isEmpty else { return nil }
        guard let raw = pdf.dataRepresentation(), let copy = PDFDocument(data: raw) else { throw ImageExporterError.encodeFailed }
        for (i, page) in flatten {
            copy.removePage(at: i)
            copy.insert(page, at: i)
        }
        return copy
    }

    private func rotation(_ page: PDFPage) -> CGAffineTransform {
        page.rotation % 180 == 0 ? .identity : CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    }

    /// A page as pixels, rotated as shown, marks included, on white.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let ns = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        var rect = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        try MainActor.assumeIsolated {
            let info = printInfo.copy() as? NSPrintInfo ?? NSPrintInfo.shared
            info.dictionary().addEntries(from: printSettings)
            guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                              userInfo: [NSLocalizedDescriptionKey: "This PDF can't be printed."])
            }
            return op
        }
    }

    // MARK: Marks (each one undoable)

    func add(_ annotation: PDFAnnotation, to page: PDFPage, name: String, redaction: Bool = false) {
        if redaction { redactions.insert(ObjectIdentifier(annotation)) }
        page.addAnnotation(annotation)
        changed(page)
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.remove(annotation, from: page, name: name) }
        }
        undoManager?.setActionName(name)
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage, name: String = "Delete Markup") {
        let wasRedaction = redactions.contains(ObjectIdentifier(annotation))
        page.removeAnnotation(annotation)
        changed(page)
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.add(annotation, to: page, name: name, redaction: wasRedaction) }
        }
        undoManager?.setActionName(name)
    }

    /// After a drag: the mark is already at `bounds` on screen; this records where it came from.
    func moved(_ annotation: PDFAnnotation, on page: PDFPage, from old: CGRect, name: String = "Move Markup") {
        let new = annotation.bounds
        guard new != old else { return }
        changed(page)
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                annotation.bounds = old
                doc.moved(annotation, on: page, from: new, name: name)
            }
        }
        undoManager?.setActionName(name)
    }

    func setText(_ text: String, bounds: CGRect, of annotation: PDFAnnotation, on page: PDFPage, name: String = "Edit Text") {
        let (oldText, oldBounds) = (annotation.contents ?? "", annotation.bounds)
        annotation.contents = text
        annotation.bounds = bounds
        changed(page)
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.setText(oldText, bounds: oldBounds, of: annotation, on: page, name: name) }
        }
        undoManager?.setActionName(name)
    }

    /// A form field was filled in or ticked (PDFKit edits the field itself; this marks the file edited).
    func formEdited() {
        updateChangeCount(.changeDone)
    }

    // MARK: Pages (each one undoable)

    var pages: [PDFPage] { (0..<pdf.pageCount).compactMap { pdf.page(at: $0) } }

    func setPages(_ new: [PDFPage], name: String) {
        guard !new.isEmpty else { return }
        let old = pages
        for i in stride(from: pdf.pageCount - 1, through: 0, by: -1) { pdf.removePage(at: i) }
        for (i, page) in new.enumerated() { pdf.insert(page, at: i) }
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.setPages(old, name: name) }
        }
        undoManager?.setActionName(name)
        onChange?(.pages)
    }

    func rotate(_ indexes: IndexSet, clockwise: Bool) {
        let targets = indexes.compactMap { pdf.page(at: $0) }
        guard !targets.isEmpty else { return }
        for page in targets {
            page.rotation = (page.rotation + (clockwise ? 90 : 270)) % 360
            pageVersions[ObjectIdentifier(page), default: 0] += 1
        }
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.rotate(IndexSet(targets.compactMap { doc.pdf.index(for: $0) }), clockwise: !clockwise) }
        }
        undoManager?.setActionName(clockwise ? "Rotate Right" : "Rotate Left")
        onChange?(.pages)
    }

    func crop(_ page: PDFPage, to rect: CGRect) {
        let old = page.bounds(for: .cropBox)
        page.setBounds(rect, for: .cropBox)
        pageVersions[ObjectIdentifier(page), default: 0] += 1
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated { doc.crop(page, to: old) }
        }
        undoManager?.setActionName("Crop")
        onChange?(.pages)
    }

    /// Pages to insert from files: every page of a PDF, one page per picture (at its print size).
    func pages(from urls: [URL]) -> [PDFPage] {
        urls.flatMap { url -> [PDFPage] in
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if type?.conforms(to: .pdf) == true, let other = PDFDocument(url: url) {
                return (0..<other.pageCount).compactMap { other.page(at: $0)?.copy() as? PDFPage }
            }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let info = try? ImageLoader.probe(src),
                  let image = try? ImageLoader.decode(src, info: info) else { return [] }
            let points = CGSize(width: info.pixelSize.width * 72 / max(info.dpi.width, 1),
                                height: info.pixelSize.height * 72 / max(info.dpi.height, 1))
            return PDFPage(image: NSImage(cgImage: image, size: points)).map { [$0] } ?? []
        }
    }

    private func changed(_ page: PDFPage) {
        pageVersions[ObjectIdentifier(page), default: 0] += 1
        onChange?(.annotations(page))
    }
}
