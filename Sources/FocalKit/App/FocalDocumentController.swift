import AppKit
import UniformTypeIdentifiers

final class FocalDocumentController: NSDocumentController {
    func open(_ url: URL) {
        let started = Date()
        openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                let ns = error as NSError
                if !(ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError) {
                    Task { @MainActor in NSApp.presentError(error) }
                }
            }
            Log.event(String(format: "open %@ completed in %.1f ms", url.lastPathComponent, Date().timeIntervalSince(started) * 1000))
        }
    }

    typealias OpenCompletion = (NSDocument?, Bool, (any Error)?) -> Void

    /// Opens that arrive together, gathered for one run-loop turn. Finder's multi-select (and `open a b c`, a
    /// drop on the Dock icon) sends one "open documents" event, which AppKit hands straight to the document
    /// controller as one call per file: the app delegate's application(_:open:) never sees them (measured: three
    /// files opened three windows).
    private var gathered: [(url: URL, completion: OpenCompletion)] = []
    private var passThrough = false
    /// An open request has arrived (so the launch-time Open panel stays away while gathered files load).
    private(set) var receivedOpenRequest = false

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping OpenCompletion) {
        receivedOpenRequest = true
        guard displayDocument, !passThrough else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        gathered.append((url, completionHandler))
        if gathered.count == 1 {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.openGathered() } }
        }
    }

    /// One file opens as usual; several Focal can show share one window, listed in its sidebar in Finder's name
    /// order with the first one showing. Types Focal can't show go through one by one so the usual error appears.
    /// A folder always opens as one window browsing its files, whatever the "several in one window" setting.
    private func openGathered() {
        var batch = gathered
        gathered = []
        batch.removeAll { item in
            guard let files = FolderNavigator.folderToBrowse(item.url) else { return false }
            if files.isEmpty {
                let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                    NSLocalizedDescriptionKey: "“\(item.url.lastPathComponent)” has no files Focal can show.",
                    NSLocalizedRecoverySuggestionErrorKey: "Focal shows pictures, PDFs, 3D models, movies and text files.",
                ])
                item.completion(nil, false, error)
            } else {
                openSet(files, completions: [item.completion])
            }
            return true
        }
        let together = Prefs.openSeveralInOneWindow ? FolderNavigator.browsable(batch.map(\.url)) : []
        let alone = together.count > 1 ? batch.filter { item in !together.contains(item.url) } : batch
        passThrough = true
        for item in alone { super.openDocument(withContentsOf: item.url, display: true, completionHandler: item.completion) }
        passThrough = false
        guard together.count > 1 else { return }
        openSet(together, completions: batch.filter { together.contains($0.url) }.map(\.completion))
    }

    /// One window showing the first file, the rest in its sidebar.
    private func openSet(_ files: [URL], completions: [OpenCompletion]) {
        let started = Date()
        super.openDocument(withContentsOf: files[0], display: false) { doc, wasOpen, error in
            MainActor.assumeIsolated {
                if let doc {
                    if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
                    (doc.windowControllers.first as? ViewerWindowController)?.browse(files)
                    doc.showWindows()
                    Log.event(String(format: "open set of %d completed in %.1f ms", files.count, Date().timeIntervalSince(started) * 1000))
                }
                // Everyone who asked gets an answer (AppKit replies to the open event); the error goes to the first.
                for (index, completion) in completions.enumerated() {
                    completion(index == 0 ? doc : nil, wasOpen, index == 0 ? error : nil)
                }
            }
        }
    }

    /// Several URLs at once (the Open panel, the app delegate): through the same gathering as Finder's opens.
    func open(_ urls: [URL]) {
        urls.forEach(open)
    }

    /// ⌘O: several files picked in the panel open together, like a Finder selection.
    /// The Open panel also takes a folder (select it and click Open; double-clicking still goes into it).
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.canChooseDirectories = true
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }

    override func openDocument(_ sender: Any?) {
        beginOpenPanel { [weak self] urls in
            guard let urls, !urls.isEmpty else { return }
            self?.open(urls)
        }
    }

    /// File ▸ New Text File: an empty, untitled text window. Saving asks for a name; the extension typed
    /// decides what it is ("notes.md" is Markdown, "todo.txt" plain text).
    func newTextFile() {
        do {
            let doc = try makeUntitledDocument(ofType: UTType.plainText.identifier)
            addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }

    /// File ▸ New from Clipboard: a copied file opens that file; copied image data opens as a new image.
    func newFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach(open)
            return
        }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) else {
            let alert = NSAlert()
            alert.messageText = "There's no image on the clipboard."
            alert.informativeText = "Copy an image or take a screenshot to the clipboard (⌃⇧⌘4), then try again."
            alert.runModal()
            return
        }
        do {
            let doc = try ImageDocument(pastedData: data)
            addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }
}
