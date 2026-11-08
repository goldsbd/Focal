import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The window's file strip: a thumbnail per file (Quick Look renders images, video frames, text, Markdown, RTF),
/// the current one highlighted. Click or ↑/↓ shows that file in the window. Rows are virtualised by the table and
/// thumbnails made off the main thread and cached, so a folder of hundreds of photos stays quick.
@MainActor
final class FileSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 200
    private static let thumbSize = CGSize(width: 168, height: 112)

    private(set) var files: [URL] = []
    private(set) var current: URL?
    var onSelect: ((URL) -> Void)?

    let table: NSTableView = SidebarTable()
    private let scroll = NSScrollView()
    private let thumbnails = NSCache<NSURL, CGImage>()
    private var settingSelection = false

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.width = Self.width - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = Self.thumbSize.height + 34
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Files")

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

    func show(_ files: [URL], current: URL?) {
        _ = view
        self.files = files
        table.reloadData()
        select(current)
    }

    /// Highlight the file now in the window (after ⌘[ / ⌘], a click, or the first open) without re-sending it.
    func select(_ url: URL?) {
        current = url
        guard let url, let row = index(of: url) else { table.deselectAll(nil); return }
        settingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        settingSelection = false
        table.scrollRowToVisible(row)
    }

    func index(of url: URL) -> Int? {
        files.firstIndex { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    var loadedThumbnailCount: Int { files.filter { thumbnails.object(forKey: $0 as NSURL) != nil }.count }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell(identifier: id)
        let url = files[row]
        cell.configure(url: url, thumbnail: thumbnails.object(forKey: url as NSURL))
        if thumbnails.object(forKey: url as NSURL) == nil { requestThumbnail(for: url) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection, table.selectedRow >= 0, table.selectedRow < files.count else { return }
        let url = files[table.selectedRow]
        guard url != current else { return }
        current = url
        onSelect?(url)
    }

    // MARK: Thumbnails

    private func requestThumbnail(for url: URL) {
        let scale = view.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: Self.thumbSize, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            guard let image = representation?.cgImage else {
                if let error { Log.event("thumbnail failed \(url.lastPathComponent): \(error.localizedDescription)") }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.thumbnailArrived(image, for: url) }
            }
        }
    }

    private func thumbnailArrived(_ image: CGImage, for url: URL) {
        thumbnails.setObject(image, forKey: url as NSURL)
        guard let row = index(of: url), let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell,
              cell.url == url else { return }
        cell.configure(url: url, thumbnail: image)
    }
}

/// One click picks a file even while Focal is behind another app (else the first click only activates it).
private final class SidebarTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Thumbnail over the file name; videos get a play badge, and until Quick Look answers, the file's icon shows.
private final class FileCell: NSTableCellView {
    private(set) var url: URL?
    private let picture = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        picture.imageScaling = .scaleProportionallyDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.masksToBounds = true
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.alignment = .center
        name.textColor = .labelColor
        badge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Video")
        badge.symbolConfiguration = .init(pointSize: 26, weight: .regular).applying(.init(paletteColors: [.white, .black.withAlphaComponent(0.55)]))
        for v in [picture, name, badge] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = picture
        textField = name
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.widthAnchor.constraint(equalToConstant: 168),
            picture.heightAnchor.constraint(equalToConstant: 112),
            name.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The cell, not its thumbnail or label, takes the click: AppKit asks the view under the pointer whether a
    /// click on a background window should go through, and the image view said no (measured: the first click
    /// only brought the window forward). The table still does the selecting.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(url: URL, thumbnail: CGImage?) {
        self.url = url
        name.stringValue = url.lastPathComponent
        toolTip = url.path
        if let thumbnail {
            picture.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        } else {
            picture.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        badge.isHidden = !(type?.conforms(to: .movie) ?? false)
    }
}
