import AppKit
import AVKit
import UniformTypeIdentifiers

/// Video window content: Apple's player view (hardware decode, HDR/EDR, frame stepping, speed, PiP)
/// plus QuickTime's Trim (⌘T, saved as a lossless passthrough copy), Loop, and Copy Frame.
final class VideoViewController: NSViewController, ViewerContent, NSMenuItemValidation {
    let document: VideoDocument
    private let playerView = AVPlayerView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var isLooping = Prefs.videoLoop
    private var naturalSize: CGSize?
    /// The real video size is known (an unplayable file only has a placeholder size: don't lock to that).
    private var sizeIsReal = false

    init(document: VideoDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var supportsMarkup: Bool { false }
    var toolbarKind: ViewerToolbar.Kind? { nil }

    override func loadView() {
        playerView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        playerView.controlsStyle = .floating
        playerView.showsFrameSteppingButtons = true
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.showsTimecodes = true
        playerView.videoGravity = .resizeAspect
        message.isHidden = true
        message.alignment = .center
        message.textColor = .white
        message.font = .systemFont(ofSize: 15)
        message.translatesAutoresizingMaskIntoConstraints = false
        playerView.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: playerView.widthAnchor, constant: -40),
        ])
        view = playerView
        startPlayer()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if mayTakeKeyboardFocus { view.window?.makeFirstResponder(playerView) }   // space, arrows, J/K/L go to the player
        applyAspectLock()
        showSize()
    }

    var keyView: NSView? { playerView }

    /// For the UI test driver: where the movie is, how fast it plays, and a way to stop it.
    var playbackTime: Double? { player?.currentItem?.currentTime().seconds }
    var playbackRate: Float { player?.rate ?? 0 }
    func pausePlayback() { player?.pause() }

    private func showSize() {
        guard sizeIsReal, let naturalSize else { return }
        view.window?.subtitle = "\(Int(naturalSize.width)) × \(Int(naturalSize.height))"
    }

    private func startPlayer() {
        guard let url = document.fileURL else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = Prefs.videoMuted
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        playerView.player = player
        self.player = player
        if Prefs.videoAutoplay { player.play() }
    }

    private func reachedEnd() {
        guard isLooping, let player else { return }
        player.seek(to: .zero)
        player.play()
    }

    func resolveNaturalSize(_ completion: @escaping @MainActor (CGSize) -> Void) {
        if let naturalSize { completion(naturalSize); return }
        guard let url = document.fileURL else { completion(CGSize(width: 640, height: 360)); return }
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let size = await VideoProbe.displaySize(of: asset)
            let playable = await VideoProbe.isPlayable(asset)
            guard let self else { return }
            if !playable {
                message.stringValue = "macOS can't play this file. AVFoundation doesn't support its format or codec (MKV and WebM need a separate player)."
                message.isHidden = false
            }
            let resolved = size ?? CGSize(width: 640, height: 120)
            naturalSize = resolved
            sizeIsReal = size != nil
            applyAspectLock()
            showSize()
            completion(resolved)
        }
    }

    /// Resizing keeps the video's shape, except in a window browsing several files (its size is the lightbox's).
    func applyAspectLock() {
        guard let window = view.window else { return }
        let browsing = (window.windowController as? ViewerWindowController)?.sidebarVisible ?? false
        if let naturalSize, sizeIsReal, !browsing {
            window.contentAspectRatio = naturalSize
        } else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)   // clears the aspect lock
        }
    }

    func teardown() {
        player?.pause()
        playerView.player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        view.window?.contentResizeIncrements = NSSize(width: 1, height: 1)   // clears the aspect lock
    }

    func inspectorRows() async -> [(String, String)] {
        guard let url = document.fileURL else { return [] }
        return await VideoProbe.inspectorRows(url: url)
    }

    // MARK: Commands

    @objc func toggleLoop(_ sender: Any?) { isLooping.toggle() }

    @objc func copy(_ sender: Any?) {
        guard let item = player?.currentItem, let url = document.fileURL else { NSSound.beep(); return }
        let time = item.currentTime()
        Task {
            do {
                let frame = try await Self.exactFrame(of: url, at: time).image
                PasteboardImage.write(frame, pointSize: CGSize(width: frame.width, height: frame.height))
            } catch {
                NSSound.beep()
            }
        }
    }

    /// The exact displayed frame (zero tolerance), rotation applied.
    private nonisolated static func exactFrame(of url: URL, at time: CMTime) async throws -> ImageBox {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return ImageBox(image: try await generator.image(at: time).image)
    }

    @objc func trimMovie(_ sender: Any?) {
        guard playerView.canBeginTrimming else { NSSound.beep(); return }
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            Task { @MainActor in self?.saveTrimmedCopy() }
        }
    }

    private func saveTrimmedCopy() {
        guard let item = player?.currentItem, let url = document.fileURL, let window = view.window else { return }
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
        let range = CMTimeRange(start: start, end: end)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (trimmed)." + url.pathExtension
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .quickTimeMovie]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let out = panel.url else { return }
            Task { @MainActor in await self?.export(url, range: range, to: out) }
        }
    }

    private func export(_ source: URL, range: CMTimeRange, to out: URL) async {
        view.window?.subtitle = "Saving trimmed copy…"
        do {
            try await Self.passthroughExport(source, range: range, to: out)
            view.window?.subtitle = "Saved \(out.lastPathComponent)"
        } catch {
            view.window?.subtitle = ""
            view.window?.presentError(error)
        }
    }

    /// Lossless trim: streams are copied, not re-encoded.
    private nonisolated static func passthroughExport(_ source: URL, range: CMTimeRange, to out: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.timeRange = range
        let type: AVFileType = switch out.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
        // The save panel already asked before replacing an existing file.
        if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
        try await session.export(to: out, as: type)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLoop(_:)):
            item.state = isLooping ? .on : .off
            return true
        case #selector(trimMovie(_:)):
            return playerView.canBeginTrimming
        default:
            return true
        }
    }
}
