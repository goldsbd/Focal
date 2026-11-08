import AppKit

/// A short message near the bottom of a view that fades away ("Saved"): confirmation without a dialog.
@MainActor
enum Toast {
    static func show(_ text: String, in host: NSView) {
        host.subviews.filter { $0.identifier == identifier }.forEach { $0.removeFromSuperview() }
        let box = NSVisualEffectView()
        box.identifier = identifier
        box.material = .hudWindow
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        host.addSubview(box)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
            box.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -24),
            box.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40),
        ])
        box.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; box.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; box.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { box.removeFromSuperview() } })
        }
    }

    private static let identifier = NSUserInterfaceItemIdentifier("FocalToast")
}
