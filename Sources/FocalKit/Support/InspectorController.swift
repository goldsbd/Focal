import AppKit

/// Floating Inspector (⌘I): image facts (size, scale, color, camera) or movie facts (codec, fps, bit rate, HDR).
/// Follows whichever viewer window is in front.
final class InspectorController: NSWindowController {
    static let shared: InspectorController = {
        let c = InspectorController()
        loaded = c
        return c
    }()
    private static weak var loaded: InspectorController?

    /// Refresh only if the Inspector has been opened (never builds the panel on the open-file path).
    static func refreshIfOpen() { loaded?.refresh() }
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var refreshTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Inspector"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isRestorable = false
        super.init(window: panel)
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        panel.contentView = root
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { InspectorController.shared.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
            return
        }
        if let main = NSApp.mainWindow {
            window.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX + 12, y: main.frame.maxY))
            if let screen = main.screen, !screen.visibleFrame.contains(window.frame) {
                window.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX - window.frame.width - 12, y: main.frame.maxY - 40))
            }
        }
        window.orderFront(nil)
        refresh()
    }

    func refresh() {
        guard let window, window.isVisible else { return }
        let content = (NSApp.mainWindow?.windowController as? ViewerWindowController)?.content
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let rows = await content?.inspectorRows() ?? [("", "No file open")]
            guard let self, !Task.isCancelled else { return }
            render(rows)
        }
    }

    private func render(_ rows: [(String, String)]) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        for (key, value) in rows {
            let k = NSTextField(labelWithString: key)
            k.textColor = .secondaryLabelColor
            let v = NSTextField(wrappingLabelWithString: value)
            v.isSelectable = true
            v.preferredMaxLayoutWidth = 240
            grid.addRow(with: [k, v])
        }
        window?.setContentSize(grid.fittingSize.applying(.identity).withPadding(28))
    }
}

private extension CGSize {
    func withPadding(_ p: CGFloat) -> CGSize { CGSize(width: max(width + p, 300), height: height + p) }
}
