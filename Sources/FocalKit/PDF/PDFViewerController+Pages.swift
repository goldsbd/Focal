import AppKit
import PDFKit

/// Page thumbnails: drag to reorder, ⌫ to delete, drop PDFs or pictures to insert, right-click to rotate or add.
extension PDFViewerController: PageStripSource {
    var pageCount: Int { document.pdf.pageCount }

    func pageLabel(for index: Int) -> String { document.pdf.page(at: index)?.label ?? "\(index + 1)" }

    func thumbnailKey(for index: Int) -> AnyHashable {
        guard let page = document.pdf.page(at: index) else { return "missing-\(index)" }
        let id = ObjectIdentifier(page)
        return "\(id.hashValue)-\(page.rotation)-\(document.pageVersions[id] ?? 0)"
    }

    /// PDFKit draws on the main thread: one page per run-loop turn, so scrolling the strip stays smooth.
    func thumbnail(for index: Int, maxPixel: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let page = self?.document.pdf.page(at: index) else { completion(nil); return }
                let size = page.bounds(for: .cropBox).size
                completion(PDFFileDocument.render(page, scale: CGFloat(maxPixel) / max(size.width, size.height, 1)))
            }
        }
    }

    var canEditPages: Bool { document.canEditPages }

    func movePages(_ indexes: IndexSet, to row: Int) {
        let all = document.pages
        let moving = indexes.map { all[$0] }
        var rest = all.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        let at = row - indexes.count(in: 0..<row)
        rest.insert(contentsOf: moving, at: min(max(at, 0), rest.count))
        guard rest != all else { return }
        document.setPages(rest, name: moving.count == 1 ? "Move Page" : "Move Pages")
        sidePanel.strip.reload(selecting: document.pdf.index(for: moving[0]))
    }

    func deletePages(_ indexes: IndexSet) {
        let rest = document.pages.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        guard !rest.isEmpty else { NSSound.beep(); return }
        document.setPages(rest, name: indexes.count == 1 ? "Delete Page" : "Delete Pages")
    }

    func insertFiles(_ urls: [URL], at row: Int) {
        let inserted = document.pages(from: urls)
        guard !inserted.isEmpty else {
            view.window.map { NSAlert(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "Those files have no pages to insert.",
            ])).beginSheetModal(for: $0) }
            return
        }
        var all = document.pages
        all.insert(contentsOf: inserted, at: min(max(row, 0), all.count))
        document.setPages(all, name: inserted.count == 1 ? "Insert Page" : "Insert Pages")
        goTo(document.pdf.index(for: inserted[0]))
    }

    func insertBlankPage(at row: Int) {
        let size = (pdfView.currentPage ?? document.pdf.page(at: 0))?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        let blank = PDFPage()
        blank.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        var all = document.pages
        all.insert(blank, at: min(max(row, 0), all.count))
        document.setPages(all, name: "Insert Blank Page")
        goTo(document.pdf.index(for: blank))
    }

    func rotatePages(_ indexes: IndexSet, clockwise: Bool) { document.rotate(indexes, clockwise: clockwise) }

    /// Edit ▸ Insert ▸ Page from File… / Blank Page: after the page showing.
    @objc func insertPageFromFile(_ sender: Any?) { sidePanel.strip.chooseFilesToInsert(at: currentPageIndex + 1) }
    @objc func insertBlankPageAfterCurrent(_ sender: Any?) { insertBlankPage(at: currentPageIndex + 1) }
    @objc func deleteCurrentPage(_ sender: Any?) { deletePages(targetPages) }
}

/// Left of the PDF: page thumbnails, and the table of contents when the PDF has one.
final class PDFSidePanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let strip = PageStripController()
    var onOutlineSelect: ((PDFOutline) -> Void)?
    var outlineRoot: PDFOutline? { didSet { if isViewLoaded { outlineChanged() } } }
    private let picker = NSSegmentedControl(labels: ["Pages", "Contents"], trackingMode: .selectOne, target: nil, action: nil)
    private let outlineView = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private var pickerHeight: NSLayoutConstraint?

    var showsContents: Bool { picker.selectedSegment == 1 && !picker.isHidden }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .withinWindow
        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(pickerChanged(_:))
        picker.controlSize = .small
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineScroll.documentView = outlineView
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true
        for v in [picker, strip.view, outlineScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let height = picker.heightAnchor.constraint(equalToConstant: 22)
        pickerHeight = height
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            picker.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            height,
            strip.view.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 6),
            strip.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            outlineScroll.topAnchor.constraint(equalTo: strip.view.topAnchor),
            outlineScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        outlineChanged()
    }

    private func outlineChanged() {
        let has = (outlineRoot?.numberOfChildren ?? 0) > 0
        picker.isHidden = !has
        pickerHeight?.constant = has ? 22 : 0
        if !has { picker.selectedSegment = 0 }
        outlineView.reloadData()
        pickerChanged(picker)
    }

    @objc private func pickerChanged(_ sender: NSSegmentedControl) {
        strip.view.isHidden = showsContents
        outlineScroll.isHidden = !showsContents
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? outlineRoot)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? outlineRoot)?.child(at: index) ?? NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = (item as? PDFOutline)?.label ?? ""
        cell.toolTip = (item as? PDFOutline)?.label
        return cell
    }

    /// Show the table of contents and pick an entry (as a click would).
    func showContents(selecting row: Int) {
        guard !picker.isHidden else { return }
        picker.selectedSegment = 1
        pickerChanged(picker)
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let item = outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline { onOutlineSelect?(item) }
    }
}
