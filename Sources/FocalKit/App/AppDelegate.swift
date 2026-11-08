import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created before launch finishes so it becomes NSDocumentController.shared.
    private let documents = FocalDocumentController()
    private var openedAtLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.mainMenu = MainMenu.build()
        Log.event("will finish launching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.event("did finish launching")
        // Paths on the command line (`Focal.app/Contents/MacOS/Focal file.png`) open too.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty {
            openedAtLaunch = true
            documents.open(paths.map { URL(fileURLWithPath: $0) })
        }
        #if DEBUG
        if UITestDriver.start(documents: documents) { openedAtLaunch = true }
        #endif
        DispatchQueue.main.async { [self] in
            if !openedAtLaunch && !documents.receivedOpenRequest && documents.documents.isEmpty { documents.openDocument(nil) }
        }
    }

    /// URL opens AppKit doesn't route to the document controller. Finder / Dock / `open` documents go straight
    /// to FocalDocumentController (which gathers several into one window); this delegate method didn't see them.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        Log.event("application(open:) \(urls.count) file(s): \(urls.map(\.lastPathComponent))")
        documents.open(urls)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.openDocument(nil) }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MarkdownPreview.removeAllPages()
        ModelLoader.removeAllTemporaryFiles()
        PasteboardImage.materializePending()
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func newFromClipboard(_ sender: Any?) { documents.newFromClipboard() }
    @objc func newTextFile(_ sender: Any?) { documents.newTextFile() }
    @objc func showInspector(_ sender: Any?) { InspectorController.shared.toggle() }
}
