import AppKit

/// Multi-page images (TIFF pages, icon sizes): a page strip on the left, Go ▸ Next/Previous Page, Go to Page.
extension ImageViewController: PageStripSource {
    var pageCount: Int { document.pageCount }

    func pageLabel(for index: Int) -> String {
        // Icons list their sizes; other files their page numbers.
        if document.info.typeIdentifier.map({ ["com.apple.icns", "com.microsoft.ico"].contains($0) }) == true,
           let size = document.pagePixelSize(index) {
            return "\(Int(size.width)) × \(Int(size.height))"
        }
        return "\(index + 1)"
    }

    func thumbnailKey(for index: Int) -> AnyHashable { "\(index)-\(document.pageVersions[index] ?? 0)" }

    func thumbnail(for index: Int, maxPixel: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        document.pageThumbnail(index, maxPixel: maxPixel, completion: completion)
    }

    @objc func nextPage(_ sender: Any?) { goTo(document.page + 1) }
    @objc func previousPage(_ sender: Any?) { goTo(document.page - 1) }

    @objc func goToPage(_ sender: Any?) {
        guard let window = view.window else { return }
        PagePrompt.ask(in: window, pageCount: document.pageCount, current: document.page) { [weak self] page in self?.goTo(page) }
    }

    @objc func togglePageStrip(_ sender: Any?) { setPageStrip(visible: !pageStripVisible) }

    func goTo(_ page: Int) {
        guard page >= 0, page < document.pageCount else { NSSound.beep(); return }
        canvas.endEditing()
        document.showPage(page)
    }
}
