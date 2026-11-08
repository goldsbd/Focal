import AppKit
import UniformTypeIdentifiers

/// What a page strip lists: a PDF's pages, or the pages of a multi-page image (TIFF pages, icon sizes).
@MainActor
protocol PageStripSource: AnyObject {
    var pageCount: Int { get }
    func pageLabel(for index: Int) -> String
    /// Changes whenever the page looks different (rotated, marked up, moved), so a stale thumbnail is never shown.
    func thumbnailKey(for index: Int) -> AnyHashable
    /// The source picks the thread (ImageIO thumbnails are made off the main thread; PDFKit draws on it).
    func thumbnail(for index: Int, maxPixel: Int, completion: @escaping @MainActor (CGImage?) -> Void)

    /// Page editing (PDF): drag to reorder, ⌫ to delete, drop files to insert, rotate from the context menu.
    var canEditPages: Bool { get }
    func movePages(_ pages: IndexSet, to row: Int)
    func deletePages(_ pages: IndexSet)
    func insertFiles(_ urls: [URL], at row: Int)
    func insertBlankPage(at row: Int)
    func rotatePages(_ pages: IndexSet, clockwise: Bool)
}

extension PageStripSource {
    var canEditPages: Bool { false }
    func movePages(_ pages: IndexSet, to row: Int) {}
    func deletePages(_ pages: IndexSet) {}
    func insertFiles(_ urls: [URL], at row: Int) {}
    func insertBlankPage(at row: Int) {}
    func rotatePages(_ pages: IndexSet, clockwise: Bool) {}
}

/// A column of page thumbnails left of the content (⌥⌘2). Click or ↑/↓ goes to a page. Rows are virtualised and
/// thumbnails cached by look, so a 1,000-page PDF opens as fast as a 2-page one.
@MainActor
final class PageStripController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let width: CGFloat = 132
    private static let thumbBox = CGSize(width: 104, height: 118)
    private static let rowType = NSPasteboard.PasteboardType("ai.digitalzoo.focal.page-rows")

    weak var source: PageStripSource?
    var onSelect: ((Int) -> Void)?
    let table: NSTableView = PageTable()
    private let scroll = NSScrollView()
    private var thumbnails: [AnyHashable: CGImage] = [:]
    private var pending: Set<AnyHashable> = []
    private var settingSelection = false

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .withinWindow
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.width = Self.width - 12
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.thumbBox.height + 26
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Pages")
        table.registerForDraggedTypes([Self.rowType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        (table as? PageTable)?.onDelete = { [weak self] in self?.deleteSelected() }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true   // fixed-height rows: no wrap/height feedback (unlike the text view)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: background.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
    }

    /// Pages were added, removed, moved or redrawn: list them again (cached thumbnails stay valid by key).
    func reload(selecting page: Int?) {
        _ = view
        table.allowsMultipleSelection = source?.canEditPages ?? false
        table.reloadData()
        select(page)
    }

    /// Highlight the page now showing (after scrolling, ⌥⌘↓, Go to Page) without sending it back.
    func select(_ page: Int?) {
        guard let page, page >= 0, page < table.numberOfRows else { return }
        guard table.selectedRowIndexes != IndexSet(integer: page) else { return }
        settingSelection = true
        table.selectRowIndexes(IndexSet(integer: page), byExtendingSelection: false)
        settingSelection = false
        table.scrollRowToVisible(page)
    }

    var selectedPages: IndexSet { table.selectedRowIndexes }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { source?.pageCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let source else { return nil }
        let id = NSUserInterfaceItemIdentifier("PageCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? PageCell) ?? PageCell(identifier: id, box: Self.thumbBox)
        let key = source.thumbnailKey(for: row)
        cell.configure(label: source.pageLabel(for: row), thumbnail: thumbnails[key], key: key)
        if thumbnails[key] == nil { requestThumbnail(row: row, key: key) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection, table.selectedRow >= 0 else { return }
        // With several selected, show the one just clicked (or the first).
        let row = table.clickedRow >= 0 && table.selectedRowIndexes.contains(table.clickedRow) ? table.clickedRow : table.selectedRow
        onSelect?(row)
    }

    private func requestThumbnail(row: Int, key: AnyHashable) {
        guard let source, !pending.contains(key) else { return }
        pending.insert(key)
        let scale = view.window?.backingScaleFactor ?? 2
        source.thumbnail(for: row, maxPixel: Int(max(Self.thumbBox.width, Self.thumbBox.height) * scale)) { [weak self] image in
            guard let self else { return }
            self.pending.remove(key)
            guard let image else { return }
            if self.thumbnails.count > 600 { self.thumbnails.removeAll() }
            self.thumbnails[key] = image
            // The row may have moved or scrolled away since; find whichever cell now shows this look.
            self.table.enumerateAvailableRowViews { rowView, _ in
                if let cell = rowView.view(atColumn: 0) as? PageCell, cell.key == key { cell.show(image) }
            }
        }
    }

    // MARK: Editing (PDF)

    private func deleteSelected() {
        guard let source, source.canEditPages, !table.selectedRowIndexes.isEmpty,
              table.selectedRowIndexes.count < source.pageCount else { NSSound.beep(); return }   // a PDF keeps one page
        source.deletePages(table.selectedRowIndexes)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard source?.canEditPages == true else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard source?.canEditPages == true else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        if info.draggingSource as? NSTableView === table { return .move }
        return fileURLs(from: info).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source, source.canEditPages else { return false }
        if info.draggingSource as? NSTableView === table {
            let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }
            guard !rows.isEmpty else { return false }
            source.movePages(IndexSet(rows), to: row)
            return true
        }
        let urls = fileURLs(from: info)
        guard !urls.isEmpty else { return false }
        source.insertFiles(urls, at: row)
        return true
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let source, source.canEditPages else { return }
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
            table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let at = clicked >= 0 ? clicked + 1 : source.pageCount
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let box = MenuAction(action)
            item.target = box
            item.representedObject = box   // keep the target alive while the menu shows
            menu.addItem(item)
        }
        if clicked >= 0 {
            add("Rotate Left") { [weak self] in self.map { source.rotatePages($0.table.selectedRowIndexes, clockwise: false) } }
            add("Rotate Right") { [weak self] in self.map { source.rotatePages($0.table.selectedRowIndexes, clockwise: true) } }
            add("Delete") { [weak self] in self?.deleteSelected() }
            menu.addItem(.separator())
        }
        add("Insert Page from File…") { [weak self] in self?.chooseFilesToInsert(at: at) }
        add("Insert Blank Page") { source.insertBlankPage(at: at) }
    }

    func chooseFilesToInsert(at row: Int) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            // The panel answers from another process, between events: insert inside one so it's a closed undo step.
            MainActor.assumeIsolated { InEvent.perform(in: window) { self?.source?.insertFiles(urls, at: row) } }
        }
    }
}

/// A closure as a menu item target.
private final class MenuAction: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}

private final class PageTable: NSTableView {
    var onDelete: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }   // ⌫, ⌦
        super.keyDown(with: event)
    }
}

private final class PageCell: NSTableCellView {
    private(set) var key: AnyHashable?
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, box: CGSize) {
        super.init(frame: .zero)
        self.identifier = identifier
        picture.imageScaling = .scaleProportionallyDown
        picture.wantsLayer = true
        picture.layer?.shadowOpacity = 0.25
        picture.layer?.shadowRadius = 2
        picture.layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        for v in [picture, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.widthAnchor.constraint(equalToConstant: box.width),
            picture.heightAnchor.constraint(equalToConstant: box.height),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 3),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The cell takes the click (the image view refused first clicks on a background window; see FileCell).
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(label text: String, thumbnail: CGImage?, key: AnyHashable) {
        self.key = key
        label.stringValue = text
        if let thumbnail { show(thumbnail) } else { picture.image = nil }
    }

    func show(_ image: CGImage) {
        picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Go ▸ Go to Page… (⌥⌘G): a page number, as a sheet.
@MainActor
enum PagePrompt {
    static func ask(in window: NSWindow, pageCount: Int, current: Int, completion: @escaping @MainActor (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "Page 1 to \(pageCount)"
        let field = NSTextField(string: String(current + 1))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            MainActor.assumeIsolated { completion(min(max(n, 1), pageCount) - 1) }
        }
    }
}
