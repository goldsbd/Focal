import AppKit
import WebKit

/// Web view that zooms with pinch or ⌘/⌥ + wheel through the window's text size (like the editor) instead of
/// WebKit's own magnification, so text size stays one remembered setting.
final class ZoomableWebView: WKWebView {
    var onZoom: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let factor = ZoomWheel.factor(for: event) { onZoom?(factor) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) { onZoom?(1 + event.magnification) }
}

/// Rendered Markdown. Page scripts are off; links open in the browser, or in Focal for local files;
/// ⌘F uses the system find bar (WKWebView is an NSTextFinderClient).
final class MarkdownPreview: NSView, WKNavigationDelegate, @preconcurrency NSTextFinderBarContainer, NSMenuItemValidation {
    let webView: ZoomableWebView
    private let finder = NSTextFinder()
    private var pendingFraction: CGFloat?
    private var documentURL: URL?
    /// The rendered page on disk. Loaded as a file so WebKit's sandboxed content process may read the
    /// pictures next to the Markdown (loadHTMLString grants no file access: relative images came up empty).
    private var pageFile: URL?
    private static let pageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("FocalMarkdown", isDirectory: true)
    /// Set once a render has finished (the test driver waits on it).
    private(set) var loaded = false

    init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = ZoomableWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .textBackgroundColor   // what shows behind the page while it loads
        // WebKit composites a page's first frames on an opaque white base, before the page's CSS applies: in dark mode a
        // window flashed white for up to two frames on 24 of 25 opens. Showing the view later (at didFinish, after a
        // snapshot) still flashed 21-23 of 25; with the base off, 0 of 25. No public API on macOS, and KVC throws on a missing key.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        } else {
            Log.event("WKWebView no longer has drawsBackground; Markdown pages may flash white while loading")
        }
        addSubview(webView)
        finder.client = webView
        finder.findBarContainer = self
        finder.isIncrementalSearchingEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Render and keep the reading position as a fraction of the page (0 = top).
    func show(markdown: String, fileURL: URL?, zoom: CGFloat, fraction: CGFloat) {
        let started = Date()
        let folder = fileURL?.deletingLastPathComponent()
        let page = MarkdownRenderer.page(markdown, base: folder)
        Log.event(String(format: "markdown rendered %d chars in %.1f ms", markdown.utf16.count, Date().timeIntervalSince(started) * 1000))
        documentURL = fileURL
        pendingFraction = fraction
        loaded = false
        webView.pageZoom = zoom
        let file = Self.pageFolder.appendingPathComponent(UUID().uuidString + ".html")
        do {
            try FileManager.default.createDirectory(at: Self.pageFolder, withIntermediateDirectories: true)
            try page.write(to: file, atomically: false, encoding: .utf8)
        } catch {
            Log.event("markdown page write failed (\(error)); pictures won't load")
            webView.loadHTMLString(page, baseURL: folder)
            return
        }
        removePageFile()
        pageFile = file
        // Read access to the whole disk so "../assets/x.png" works too. Page scripts are off, so the page can
        // show local files but has no way to send them anywhere.
        webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    /// At quit: windows aren't closed (no teardown), so clear every rendered page at once.
    static func removeAllPages() {
        try? FileManager.default.removeItem(at: pageFolder)
    }

    private func removePageFile() {
        if let pageFile { try? FileManager.default.removeItem(at: pageFile) }
        pageFile = nil
    }

    func setZoom(_ zoom: CGFloat) { webView.pageZoom = zoom }

    /// Where the reader is, 0…1 (app-injected JavaScript still runs with page scripts off).
    func scrollFraction() async -> CGFloat {
        let js = "scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)"
        let value = try? await webView.evaluateJavaScript(js)
        return CGFloat((value as? NSNumber)?.doubleValue ?? 0)
    }

    func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        removePageFile()
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let fraction = pendingFraction, fraction > 0 {
            webView.evaluateJavaScript("scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - innerHeight))")
        }
        pendingFraction = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.isFileURL, url.path == pageFile?.path { return .allow }   // our page (first load, re-render, #jump untitled)
        // Nothing else loads in here: no <meta refresh> or form redirects, only links the person clicks.
        guard action.navigationType == .linkActivated else { return .cancel }
        // "#section" (resolved against the <base>, the file's folder) or "this-file.md#section": jump in the page.
        if let fragment = url.fragment(percentEncoded: false), url.isFileURL,
           url.path == documentURL?.path || url.path == documentURL?.deletingLastPathComponent().path {
            let id = String(data: (try? JSONEncoder().encode(fragment)) ?? Data(), encoding: .utf8) ?? "\"\""
            _ = try? await webView.evaluateJavaScript("document.getElementById(\(id))?.scrollIntoView()")
            return .cancel
        }
        if url.isFileURL, let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, FolderNavigator.isViewable(type) {
            (NSDocumentController.shared as? FocalDocumentController)?.open(url)   // another .md, an image…
        } else {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    // MARK: Find bar

    var findBarView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            needsLayout = true
        }
    }

    var isFindBarVisible = false {
        didSet {
            if isFindBarVisible, let bar = findBarView, bar.superview == nil { addSubview(bar) }
            if !isFindBarVisible { findBarView?.removeFromSuperview() }
            needsLayout = true
        }
    }

    func findBarViewDidChangeHeight() { needsLayout = true }

    override func layout() {
        super.layout()
        var webFrame = bounds
        if isFindBarVisible, let bar = findBarView {
            let height = bar.frame.height
            bar.frame = NSRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: height)
            webFrame.size.height -= height
        }
        webView.frame = webFrame
    }

    /// The Edit ▸ Find items (tagged NSTextFinder actions) reach here up the responder chain from the web view.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) else { return }
        finder.performAction(action)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performFindPanelAction(_:)), let action = NSTextFinder.Action(rawValue: item.tag) else { return true }
        return finder.validateAction(action)
    }
}
