import AppKit

/// The Markup bar under the toolbar: tools, colors, size.
final class MarkupAccessoryController: NSTitlebarAccessoryViewController {
    private let state: MarkupState
    private let tools = NSSegmentedControl()
    private let sizes = NSSegmentedControl()
    private var swatches: [SwatchButton] = []
    private let well = NSColorWell(style: .minimal)
    private let hint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var observer: NSObjectProtocol?
    /// The tools this window's content offers (pictures and PDFs differ); set before the bar shows.
    private(set) var toolList = MarkupState.Tool.imageTools
    /// Content-specific help under each tool (a PDF's Move/Select selects text; a picture's pans).
    var hintProvider: ((MarkupState.Tool) -> String?)?

    /// Width the tools, colors and sizes need. The hint sits outside the stack in whatever room is left,
    /// so this is exactly the bar's minimum width.
    var essentialWidth: CGFloat {
        _ = view
        return ceil(stack.fittingSize.width)
    }

    init(state: MarkupState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        tools.trackingMode = .selectOne
        tools.segmentStyle = .separated
        buildToolSegments()
        tools.target = self
        tools.action = #selector(toolPicked(_:))

        swatches = RGBAColor.palette.map { entry in
            let b = SwatchButton(color: entry.color, name: entry.name)
            b.target = self
            b.action = #selector(swatchPicked(_:))
            return b
        }
        let swatchStack = NSStackView(views: swatches)
        swatchStack.spacing = 2

        well.target = self
        well.action = #selector(wellChanged(_:))
        well.toolTip = "Other color"

        let allSizes = MarkupState.Size.allCases
        sizes.segmentCount = allSizes.count
        sizes.trackingMode = .selectOne
        for (i, size) in allSizes.enumerated() {
            sizes.setImage(Self.lineImage(width: [1, 2.5, 4, 6][i]), forSegment: i)
            sizes.setToolTip(size.label, forSegment: i)
            sizes.setWidth(26, forSegment: i)
        }
        sizes.target = self
        sizes.action = #selector(sizePicked(_:))

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [tools, Self.divider(), swatchStack, well, Self.divider(), sizes].forEach(stack.addArrangedSubview)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        root.addSubview(stack)
        root.addSubview(hint)
        // Both below NSLayoutConstraint.Priority.windowSizeStayPut (500): the hint only uses room that is
        // already there and truncates to nothing, it never makes the window wider.
        let hintGap = hint.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4)
        hintGap.priority = NSLayoutConstraint.Priority(480)
        let hintEnd = hint.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12)
        hintEnd.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            hintGap,
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor),
            hintEnd,
            hint.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        refresh()
        observer = NotificationCenter.default.addObserver(forName: MarkupState.didChange, object: state, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setTools(_ list: [MarkupState.Tool]) {
        guard list != toolList else { return }
        toolList = list
        if !list.contains(state.tool) { state.tool = .select }
        if isViewLoaded { buildToolSegments(); refresh() }
    }

    private func buildToolSegments() {
        tools.segmentCount = toolList.count
        for (i, tool) in toolList.enumerated() {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label), forSegment: i)
            tools.setToolTip("\(tool.label)  (\(String(tool.shortcut).uppercased()))", forSegment: i)
            tools.setWidth(28, forSegment: i)
        }
    }

    private func refresh() {
        tools.selectedSegment = toolList.firstIndex(of: state.tool) ?? 0
        sizes.selectedSegment = state.size.rawValue
        swatches.forEach { $0.isChosen = $0.swatchColor == state.color }
        well.color = state.color.nsColor
        let generic: String = switch state.tool {
        case .crop: "Drag to choose the area · Return crops · Esc cancels"
        case .text: "Click to type · Return finishes · ⌥Return new line"
        case .select: "Drag to move the image · click a mark to select it · Delete removes"
        case .redact: "Solid box: hides what's under it for good once saved"
        default: "Shift constrains · space-drag pans · ⌘Z undoes"
        }
        hint.stringValue = hintProvider?(state.tool) ?? generic
    }

    @objc private func toolPicked(_ sender: NSSegmentedControl) {
        state.tool = toolList[sender.selectedSegment]
        sender.window?.makeFirstResponder(canvasInWindow(sender.window))
    }

    @objc private func swatchPicked(_ sender: SwatchButton) { state.color = sender.swatchColor }

    @objc private func wellChanged(_ sender: NSColorWell) {
        if let c = RGBAColor(sender.color) { state.color = c }
    }

    @objc private func sizePicked(_ sender: NSSegmentedControl) {
        state.size = MarkupState.Size(rawValue: sender.selectedSegment) ?? .medium
        sender.window?.makeFirstResponder(canvasInWindow(sender.window))
    }

    private func canvasInWindow(_ window: NSWindow?) -> NSResponder? {
        (window?.windowController as? ViewerWindowController)?.content?.keyView
    }

    private static func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    private static func lineImage(width: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: r.midY - width / 2, width: r.width - 4, height: width),
                         xRadius: width / 2, yRadius: width / 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Round color chip; a ring marks the current color.
final class SwatchButton: NSButton {
    let swatchColor: RGBAColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: RGBAColor, name: String) {
        swatchColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = name
        setAccessibilityLabel(name)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let chip = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        swatchColor.nsColor.setFill()
        chip.fill()
        NSColor.separatorColor.setStroke()
        chip.lineWidth = 1
        chip.stroke()
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}
