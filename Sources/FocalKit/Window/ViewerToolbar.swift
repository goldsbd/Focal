import AppKit

/// Window toolbar. Items send their actions up the responder chain to the image or text controller.
@MainActor
final class ViewerToolbar: NSObject, NSToolbarDelegate {
    enum Kind { case image, text, markdown, video, pdf, model }

    let kind: Kind
    let toolbar: NSToolbar
    private var markupItem: NSToolbarItem?
    private(set) var searchItem: NSSearchToolbarItem?

    private static let zoomOut = NSToolbarItem.Identifier("zoomOut")
    private static let zoomIn = NSToolbarItem.Identifier("zoomIn")
    private static let zoomFit = NSToolbarItem.Identifier("zoomFit")
    private static let rotate = NSToolbarItem.Identifier("rotate")
    private static let markup = NSToolbarItem.Identifier("markup")
    private static let save = NSToolbarItem.Identifier("save")
    private static let sidebar = NSToolbarItem.Identifier("fileSidebar")
    private static let pages = NSToolbarItem.Identifier("pageThumbnails")
    private static let search = NSToolbarItem.Identifier("search")
    private static let resetView = NSToolbarItem.Identifier("resetView")

    init(kind: Kind) {
        self.kind = kind
        // Distinct identifiers: toolbars sharing one identifier mirror each other's items.
        let identifier = switch kind {
        case .image: "FocalImageToolbar"
        case .text: "FocalTextToolbar"
        case .markdown: "FocalMarkdownToolbar"
        case .video: "FocalVideoToolbar"
        case .pdf: "FocalPDFToolbar"
        case .model: "FocalModelToolbar"
        }
        toolbar = NSToolbar(identifier: identifier)
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        switch kind {
        case .image: [Self.sidebar, .flexibleSpace, Self.zoomOut, Self.zoomIn, Self.zoomFit, .space, Self.rotate, Self.markup, .space, Self.save]
        case .text: [Self.sidebar, .flexibleSpace, Self.zoomOut, Self.zoomIn, .space, Self.save]
        case .markdown: [Self.sidebar, .flexibleSpace, TextViewController.markdownModeItem, .space, Self.zoomOut, Self.zoomIn, .space, Self.save]
        case .video: [Self.sidebar, .flexibleSpace]
        case .pdf: [Self.sidebar, .flexibleSpace, Self.pages, Self.zoomOut, Self.zoomIn, Self.zoomFit, .space, Self.rotate, Self.markup,
                    .space, Self.search, Self.save]
        case .model: [Self.sidebar, .flexibleSpace, Self.resetView]
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == TextViewController.markdownModeItem {
            // Rendered or source; the text controller keeps the selection in step with ⇧⌘P.
            let group = NSToolbarItemGroup(itemIdentifier: id, titles: ["Preview", "Edit"], selectionMode: .selectOne,
                                           labels: ["Preview", "Edit"], target: nil,
                                           action: #selector(TextViewController.markdownModeChanged(_:)))
            group.label = "View"
            group.toolTip = "Show the rendered page or edit the Markdown (⇧⌘P)"
            group.selectedIndex = 0
            return group
        }
        if id == Self.search {
            // Searches as you type (after a pause); Return goes to the next match.
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search"
            item.searchField.action = #selector(PDFViewerController.searchChanged(_:))
            item.searchField.target = nil
            item.label = "Search"
            item.preferredWidthForSearchField = 200
            searchItem = item
            return item
        }
        if id == Self.save {
            // A word, not an icon: the one button that matters after marking up or editing. Greyed when nothing
            // to save. Image and text controllers both answer quickSave: up the responder chain.
            let item = NSToolbarItem(itemIdentifier: id)
            item.title = "Save"
            item.label = "Save"
            item.toolTip = "Save (⌘S)"
            item.action = #selector(ImageViewController.quickSave(_:))
            item.isBordered = true
            return item
        }
        let spec: (symbol: String, label: String, action: Selector)
        switch id {
        case Self.zoomOut: spec = (isText ? "textformat.size.smaller" : "minus.magnifyingglass",
                                   isText ? "Smaller Text" : "Zoom Out", #selector(ImageViewController.zoomOut(_:)))
        case Self.zoomIn: spec = (isText ? "textformat.size.larger" : "plus.magnifyingglass",
                                  isText ? "Bigger Text" : "Zoom In", #selector(ImageViewController.zoomIn(_:)))
        case Self.pages: spec = ("sidebar.squares.left", "Page Thumbnails", #selector(ImageViewController.togglePageStrip(_:)))
        case Self.resetView: spec = ("arrow.counterclockwise", "Reset View", #selector(ModelViewController.resetView(_:)))
        case Self.zoomFit: spec = ("arrow.up.left.and.down.right.magnifyingglass", "Zoom to Fit", #selector(ImageViewController.zoomToFit(_:)))
        case Self.rotate: spec = ("rotate.left", "Rotate Left", #selector(ImageViewController.rotateLeft(_:)))
        case Self.markup: spec = ("pencil.tip.crop.circle", "Markup", #selector(ImageViewController.toggleMarkup(_:)))
        case Self.sidebar: spec = ("sidebar.left", "Sidebar", #selector(ViewerWindowController.toggleFileSidebar(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.label = spec.label
        item.toolTip = spec.label
        item.action = spec.action
        item.isBordered = true
        if id == Self.markup { markupItem = item }
        return item
    }

    private var isText: Bool { kind == .text || kind == .markdown }

    func setMarkupActive(_ active: Bool) {
        markupItem?.image = NSImage(systemSymbolName: active ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                                    accessibilityDescription: "Markup")
    }
}
