import AppKit

/// Puts an image on the clipboard as PNG and TIFF, encoded only when an app actually pastes it.
@MainActor
enum PasteboardImage {
    private static var provider: Provider?   // must outlive the clipboard entry

    static func write(_ image: CGImage, pointSize: CGSize) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize   // keeps Retina screenshots at their true size when pasted
        let p = Provider(rep: rep)
        let item = NSPasteboardItem()
        item.setDataProvider(p, forTypes: [.png, .tiff])
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        provider = p
    }

    /// Before quitting, hand over anything still only promised, so a copy survives Focal quitting.
    static func materializePending() {
        guard let p = provider, let item = NSPasteboard.general.pasteboardItems?.first else { return }
        for type in [NSPasteboard.PasteboardType.png, .tiff] where item.types.contains(type) {
            _ = item.data(forType: type)   // asks the provider now, while it still exists
        }
        _ = p
    }

    final class Provider: NSObject, NSPasteboardItemDataProvider {
        let rep: NSBitmapImageRep
        init(rep: NSBitmapImageRep) { self.rep = rep }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            switch type {
            case .png: if let d = rep.representation(using: .png, properties: [:]) { item.setData(d, forType: .png) }
            case .tiff: if let d = rep.tiffRepresentation { item.setData(d, forType: .tiff) }
            default: break
            }
        }
    }
}
