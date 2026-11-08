import AppKit
import UniformTypeIdentifiers

/// "Open images/videos with Focal" — sets this app as the Launch Services default per file type.
@MainActor
enum DefaultApp {
    static let imageTypes: [UTType] = [
        .png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP, .ico,
        UTType("public.avif"), UTType("public.jpeg-2000"), UTType("com.adobe.photoshop-image"),
    ].compactMap { $0 }

    static let videoTypes: [UTType] = [
        .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video, .mpeg2TransportStream,
        UTType("com.apple.m4v-video"), UTType("public.3gpp"), UTType("public.avchd-mpeg-2-transport-stream"),
    ].compactMap { $0 }

    static let textTypes: [UTType] = [.plainText, UTType(TextFormat.markdownType), .rtf].compactMap { $0 }

    static func makeDefault(for types: [UTType]) async -> String {
        let app = Bundle.main.bundleURL
        var done = 0
        var failed: [String] = []
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                done += 1
            } catch {
                failed.append(type.preferredFilenameExtension ?? type.identifier)
            }
        }
        return failed.isEmpty ? "Focal now opens \(done) file types."
            : "Set \(done) file types; couldn't set: \(failed.joined(separator: ", "))."
    }
}
