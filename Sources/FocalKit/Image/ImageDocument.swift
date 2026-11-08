import AppKit
import UniformTypeIdentifiers

/// CGImage is immutable, so handing one across threads is safe.
struct ImageBox: @unchecked Sendable { let image: CGImage }

/// An image file. Opening reads only the header (so the window is sized and placed at once) and
/// decodes the pixels on a background thread. Edits are whole-state snapshots, which makes undo exact.
@objc(ImageDocument)
final class ImageDocument: NSDocument {
    enum Change { case loaded, geometry, annotations, page, failed(String) }

    private(set) var info = ImageInfo.empty
    /// Pages of a multi-page image (a TIFF's pages, an icon's sizes); 1 otherwise. `info` and `state` are the
    /// page showing; edits to other pages wait in `pageStates` and are all written by Save.
    private(set) var pageCount = 1
    private(set) var page = 0
    private var pageStates: [Int: EditState] = [:]
    private(set) var editedPages: Set<Int> = []
    /// Bumped on every edit of a page, so the page strip redraws that thumbnail.
    private(set) var pageVersions: [Int: Int] = [:]
    private(set) var state: EditState?
    private(set) var loadError: String?
    var onChange: ((Change) -> Void)?
    private var decodeTask: Task<Void, Never>?

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(ViewerWindowController())
    }

    /// NSDocument declares this nonisolated (it may run concurrently when a subclass opts in). This class
    /// doesn't opt in (canConcurrentlyReadDocuments stays false), so it always runs on the main thread;
    /// assumeIsolated asserts that rather than racing silently if it ever changes.
    override func read(from url: URL, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            state = nil
            loadError = nil
            page = 0
            pageCount = 1
            pageStates = [:]
            editedPages = []
            pageVersions = [:]
            let source = try ImageLoader.source(url: url)
            do {
                info = try ImageLoader.probe(source)
            } catch {
                guard let raster = ImageLoader.decodeFallback(url: url) else { throw error }
                info = raster.info
                state = EditState(image: raster.image)
                return
            }
            pageCount = ImageLoader.pageCount(source)
            Log.event("probed \(url.lastPathComponent) \(Int(info.pixelSize.width))×\(Int(info.pixelSize.height))\(pageCount > 1 ? ", \(pageCount) pages" : "")")
            let info = self.info
            startDecoding(page: 0) { try ImageLoader.decode(try ImageLoader.source(url: url), info: info) }
        }
    }

    /// New document from clipboard image data (File ▸ New from Clipboard).
    convenience init(pastedData data: Data) throws {
        self.init()
        let source = try ImageLoader.source(data: data)
        info = try ImageLoader.probe(source)
        state = EditState(image: try ImageLoader.decode(source, info: info))
        fileType = UTType.png.identifier
    }

    /// Show another page. Its edits (if it was visited) come back from `pageStates`; otherwise it is decoded.
    func showPage(_ index: Int) {
        guard index != page, index >= 0, index < pageCount, let url = fileURL else { return }
        if let state { pageStates[page] = state }
        page = index
        loadError = nil
        do {
            info = try ImageLoader.probe(try ImageLoader.source(url: url), index: index)
        } catch {
            state = nil
            loadError = error.localizedDescription
            onChange?(.failed(error.localizedDescription))
            return
        }
        state = pageStates[index]
        onChange?(.page)   // sized to the new page at once; the pixels follow with .loaded if not decoded yet
        if state == nil {
            let info = self.info
            startDecoding(page: index) { try ImageLoader.decode(try ImageLoader.source(url: url), info: info, index: index) }
        }
    }

    /// How a page looks now, for its thumbnail: edited pages drawn with their marks, the rest straight from the file.
    func pageThumbnail(_ index: Int, maxPixel: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        let edited = editedPages.contains(index) ? (index == page ? state : pageStates[index]).flatMap { Flattener.flatten($0) } : nil
        let box = edited.map(ImageBox.init)
        let url = fileURL
        Task.detached(priority: .utility) {
            let image: CGImage? = if let box {
                ImageOps.displayImage(box.image, maxPixel: maxPixel)
            } else {
                url.flatMap { try? ImageLoader.source(url: $0) }.flatMap { ImageLoader.thumbnail($0, index: index, maxPixel: maxPixel) }
            }
            let result = image.map(ImageBox.init)
            await MainActor.run { completion(result?.image) }
        }
    }

    /// Header size of a page without decoding it (page strip labels for icon sizes).
    func pagePixelSize(_ index: Int) -> CGSize? {
        guard let url = fileURL, let src = try? ImageLoader.source(url: url) else { return nil }
        return try? ImageLoader.probe(src, index: index).pixelSize
    }

    private func startDecoding(page: Int, _ work: @escaping @Sendable () throws -> CGImage) {
        decodeTask?.cancel()
        let started = Date()
        decodeTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { ImageBox(image: try work()) } }.value
            guard let self, !Task.isCancelled, self.page == page else { return }
            switch result {
            case .success(let box):
                state = EditState(image: box.image)
                Log.event(String(format: "decoded in %.1f ms", Date().timeIntervalSince(started) * 1000))
                onChange?(.loaded)
            case .failure(let error):
                loadError = error.localizedDescription
                onChange?(.failed(error.localizedDescription))
            }
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        undoManager?.removeAllActions()
        onChange?(.geometry)
    }

    override func close() {
        decodeTask?.cancel()
        super.close()
    }

    // MARK: Saving

    override func data(ofType typeName: String) throws -> Data {
        guard let state else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "The image is still loading."])
        }
        guard let type = UTType(typeName) else { throw ImageExporterError.unsupportedType(typeName) }
        // Every page goes, edited ones redrawn and the rest copied as they were (to a one-image format, the page showing).
        if pageCount > 1, let url = fileURL, ImageExporter.multiPageTypes.contains(where: type.conforms(to:)) {
            var all = pageStates
            all[page] = state
            var edited: [Int: CGImage] = [:]
            for i in editedPages {
                guard let s = all[i], let flat = Flattener.flatten(s) else { throw ImageExporterError.encodeFailed }
                edited[i] = flat
            }
            return try ImageExporter.encodePages(from: ImageLoader.source(url: url), replacing: edited, as: type, dpi: info.dpi)
        }
        // An animation can't be edited, so saving it elsewhere copies its frames as they are (a GIF stays animated).
        if info.isAnimated, let url = fileURL, ImageExporter.animatedTypes.contains(where: type.conforms(to:)) {
            return try ImageExporter.copyFrames(from: ImageLoader.source(url: url), as: type)
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        guard let flat = Flattener.flatten(state, background: type.conforms(to: .jpeg) ? white : nil) else {
            throw ImageExporterError.encodeFailed
        }
        return try ImageExporter.encode(flat, as: type, dpi: info.dpi, sourceProperties: info.properties)
    }

    /// Save As offers the formats Focal edits in place (Info.plist Editor roles); Export adds the ones Preview
    /// exports to but doesn't edit (OpenEXR, PDF).
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        var types = super.writableTypes(for: saveOperation)
        if saveOperation == .saveToOperation {
            for extra in [UTType.pdf, UTType("com.ilm.openexr-image")!].map(\.identifier) where !types.contains(extra) {
                types.append(extra)
            }
        }
        return types
    }

    /// File ▸ Print: the picture (with its marks) fitted to the page, centred, turned to landscape when wide.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        try MainActor.assumeIsolated {
            guard let image = flattenedImage() else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "The image is still loading."])
            }
            let info = printInfo.copy() as? NSPrintInfo ?? NSPrintInfo.shared
            info.dictionary().addEntries(from: printSettings)
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            info.orientation = image.width > image.height ? .landscape : .portrait
            let size = canvasPointSize
            let view = NSImageView(frame: NSRect(origin: .zero, size: size))
            view.image = NSImage(cgImage: image, size: size)
            view.imageScaling = .scaleProportionallyUpOrDown
            return NSPrintOperation(view: view, printInfo: info)
        }
    }

    func flattenedImage() -> CGImage? { state.flatMap { Flattener.flatten($0) } }

    var canvasPointSize: CGSize {
        let r = state?.canvasRect.size ?? info.pixelSize
        return CGSize(width: r.width / info.pixelsPerPoint, height: r.height / info.pixelsPerPoint)
    }

    // MARK: Edits (each one undoable)

    func addAnnotation(_ a: Annotation) {
        mutate("Add \(a.kind.label)") { $0.annotations.append(a) }
    }

    func replaceAnnotation(_ a: Annotation) {
        mutate("Change \(a.kind.label)") { s in
            if let i = s.annotations.firstIndex(where: { $0.id == a.id }) { s.annotations[i] = a }
        }
    }

    func removeAnnotation(id: UUID) {
        mutate("Delete Markup") { $0.annotations.removeAll { $0.id == id } }
    }

    func rotate(clockwise: Bool) {
        guard let rotated = state?.rotated(clockwise: clockwise) else { return }
        commit(rotated, name: clockwise ? "Rotate Right" : "Rotate Left", change: .geometry)
    }

    func crop(to rect: CGRect) {
        guard let s = state else { return }
        commit(s.cropped(to: rect), name: "Crop", change: .geometry)
    }

    private func mutate(_ name: String, _ body: (inout EditState) -> Void) {
        guard var s = state else { return }
        body(&s)
        commit(s, name: name, change: .annotations)
    }

    private func commit(_ new: EditState, name: String, change: Change) {
        guard let old = state else { return }
        let onPage = page
        undoManager?.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                if doc.page != onPage { doc.showPage(onPage) }   // undo goes back to the page it changes
                doc.commit(old, name: name, change: change)
            }
        }
        undoManager?.setActionName(name)
        state = new
        editedPages.insert(page)
        pageVersions[page, default: 0] += 1
        onChange?(change)
    }
}
