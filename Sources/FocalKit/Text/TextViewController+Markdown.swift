import AppKit

/// Markdown files open rendered; Preview / Edit (toolbar, View menu ⇧⌘P) switches to the plain-text editor and
/// back, keeping your place in the document.
extension TextViewController {
    static let markdownModeItem = NSToolbarItem.Identifier("markdownMode")

    @objc func togglePreview(_ sender: Any?) { setMode(mode == .preview ? .edit : .preview) }

    /// The toolbar's Preview | Edit control.
    @objc func markdownModeChanged(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        setMode(group.selectedIndex == 0 ? .preview : .edit)
    }

    func setMode(_ new: Mode) {
        guard new == .edit || document.format == .markdown else { return }
        let wasEditing = mode == .edit || preview?.isHidden != false
        mode = new
        switch new {
        case .preview:
            let page = preview ?? makePreview()
            page.show(markdown: document.text, fileURL: document.fileURL, zoom: previewZoom,
                      fraction: wasEditing ? editorFraction() : 0)
            page.isHidden = false
            scrollView.isHidden = true
            view.window?.makeFirstResponder(page.webView)
        case .edit:
            if let page = preview, !page.isHidden {
                page.isHidden = true
                Task { [weak self] in
                    let fraction = await page.scrollFraction()
                    self?.scrollEditor(to: fraction)
                }
            }
            scrollView.isHidden = false
            view.window?.makeFirstResponder(textView)
        }
        syncModeControl()
    }

    func rerenderPreview() {
        guard let page = preview else { return }
        Task { [weak self] in
            guard let self else { return }
            let fraction = await page.scrollFraction()
            page.show(markdown: self.document.text, fileURL: self.document.fileURL, zoom: self.previewZoom, fraction: fraction)
        }
    }

    private func makePreview() -> MarkdownPreview {
        let page = MarkdownPreview()
        page.frame = view.bounds
        page.autoresizingMask = [.width, .height]
        page.webView.onZoom = { [weak self] factor in
            guard let self else { return }
            self.setFontSize(self.fontSize * factor)
        }
        view.addSubview(page)
        preview = page
        return page
    }

    /// Keep the toolbar's Preview | Edit selection in step with the menu and shortcut.
    func syncModeControl() {
        guard let group = view.window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.markdownModeItem }) as? NSToolbarItemGroup else { return }
        group.selectedIndex = mode == .preview ? 0 : 1
    }

    /// How far down the editor is scrolled, 0…1.
    private func editorFraction() -> CGFloat {
        let clip = scrollView.contentView.bounds
        let scrollable = textView.frame.height - clip.height
        return scrollable > 0 ? min(1, max(0, clip.minY / scrollable)) : 0
    }

    private func scrollEditor(to fraction: CGFloat) {
        guard fraction > 0 else { return }
        let scrollable = textView.frame.height - scrollView.contentView.bounds.height
        textView.scroll(NSPoint(x: 0, y: fraction * scrollable))
    }
}
