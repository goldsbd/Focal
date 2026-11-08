import AppKit

/// A movie file. Nothing is read up front: AVFoundation streams it (hardware decode on the media engine).
@objc(VideoDocument)
final class VideoDocument: NSDocument {
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(ViewerWindowController())
    }

    override func read(from url: URL, ofType typeName: String) throws {
        Log.event("video \(url.lastPathComponent)")
    }

    /// Movies are trimmed (⌘T), not exported or printed: File ▸ Export… and Print… stay off.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        [#selector(saveTo(_:)), #selector(printDocument(_:))].contains(item.action) ? false : super.validateUserInterfaceItem(item)
    }
}
