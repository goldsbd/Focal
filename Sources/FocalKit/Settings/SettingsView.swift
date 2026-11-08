import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(Prefs.Key.placement) private var placement: PlacementPolicy = .centerOnMainDisplay
    @AppStorage(Prefs.Key.fitPercent) private var fitPercent: Double = 80
    @AppStorage(Prefs.Key.allowUpscale) private var allowUpscale = false
    @AppStorage(Prefs.Key.offsetStacked) private var offsetStacked = true
    @AppStorage(Prefs.Key.openTogether) private var openTogether = true
    @AppStorage(Prefs.Key.showMarkupOnOpen) private var showMarkupOnOpen = true
    @AppStorage(Prefs.Key.wheelZooms) private var wheelZooms = true
    @AppStorage(Prefs.Key.videoAutoplay) private var autoplay = true
    @AppStorage(Prefs.Key.videoLoop) private var loop = false
    @AppStorage(Prefs.Key.videoMuted) private var muted = false
    @AppStorage(Prefs.Key.textFontSize) private var textSize = Prefs.defaultTextSize
    @AppStorage(Prefs.Key.textMonospaced) private var textMonospaced = true
    @AppStorage(Prefs.Key.textWraps) private var textWraps = true
    @State private var status = ""
    @State private var working = false

    var body: some View {
        Form {
            Section("New windows") {
                Picker("Open at", selection: $placement) {
                    ForEach(PlacementPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("The main display is the one with the menu bar, set in System Settings → Displays.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Largest size") {
                    HStack {
                        Slider(value: $fitPercent, in: 40...100, step: 5)
                        Text("\(Int(fitPercent))% of the screen").monospacedDigit().frame(width: 130, alignment: .leading)
                    }
                }
                Toggle("Enlarge small images to fill the window", isOn: $allowUpscale)
                Toggle("Open several files at once in one window, with a thumbnail sidebar", isOn: $openTogether)
                Toggle("Offset windows slightly when several open at once", isOn: $offsetStacked)
                Toggle("Show the Markup tools when an image opens", isOn: $showMarkupOnOpen)
            }
            Section("Mouse") {
                Picker("Scroll wheel", selection: $wheelZooms) {
                    Text("Zooms around the pointer").tag(true)
                    Text("Scrolls the image").tag(false)
                }
                .pickerStyle(.radioGroup)
                Text("Hold ⌘ or ⌥ while scrolling to do the other one. Drag the image to move it. In text windows the wheel scrolls and ⌘-scroll zooms.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Video") {
                Toggle("Start playing when opened", isOn: $autoplay)
                Toggle("Loop", isOn: $loop)
                Toggle("Start muted", isOn: $muted)
            }
            Section("Text") {
                LabeledContent("Text size") {
                    Stepper("\(textSize.formatted()) pt", value: $textSize, in: 8...120, step: 1).monospacedDigit()
                }
                Text("Zooming a text window (⌘+ / ⌘−, pinch, ⌘-scroll) changes this, and new windows open at the size you left.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Font", selection: $textMonospaced) {
                    Text("Monospaced").tag(true)
                    Text("Proportional").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Wrap long lines", isOn: $textWraps)
            }
            Section("Default app") {
                HStack {
                    Button("Open images with Focal") { setDefault(DefaultApp.imageTypes) }
                    Button("Open videos with Focal") { setDefault(DefaultApp.videoTypes) }
                    Button("Open text, Markdown & RTF with Focal") { setDefault(DefaultApp.textTypes) }
                }
                .disabled(working)
                if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setDefault(_ types: [UTType]) {
        working = true
        status = "Working…"
        Task { @MainActor in
            status = await DefaultApp.makeDefault(for: types)
            working = false
        }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "Focal Settings"
        window.styleMask = [.titled, .closable]
        window.isRestorable = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        guard let window else { return }
        if !window.isVisible, let main = NSScreen.screens.first?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: main.midX - window.frame.width / 2, y: main.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
    }
}
