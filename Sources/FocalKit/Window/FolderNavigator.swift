import Foundation
import UniformTypeIdentifiers

/// Next / previous viewable file in the same folder, in Finder's name order.
public enum FolderNavigator {
    public static func isViewable(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .plainText) || type.conforms(to: .rtf)
            || type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) || type.conforms(to: .pdf)
            || ModelLoader.route(for: type) != nil
    }

    public static func siblings(of url: URL) -> [URL] {
        contents(ofFolder: url.deletingLastPathComponent())
    }

    /// The viewable files directly inside a folder, in Finder's name order. Packages count as files (an RTFD is a
    /// document); subfolders and hidden files are left out.
    public static func contents(ofFolder folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { item in
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true || v.isPackage == true,
                  let type = v.contentType else { return false }
            return isViewable(type)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A folder opened in Focal (dropped on the Dock icon, picked in the Open panel): the files to browse in one
    /// window. Nil when `url` is a file or a package, which open as documents.
    public static func folderToBrowse(_ url: URL) -> [URL]? {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .folder)
        else { return nil }
        return contents(ofFolder: url)
    }

    /// Files opened together, as the sidebar lists them: only what Focal shows, in Finder's name order.
    public static func browsable(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType).map(isViewable) ?? false
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Neighbour by name (paths may differ in /private or symlink spelling). No wrap-around.
    public static func neighbor(of url: URL, in files: [URL], offset: Int) -> URL? {
        guard let i = files.firstIndex(where: { $0.lastPathComponent == url.lastPathComponent }) else { return nil }
        let j = i + offset
        return files.indices.contains(j) ? files[j] : nil
    }
}
