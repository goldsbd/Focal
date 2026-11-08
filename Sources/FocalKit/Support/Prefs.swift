import Foundation
import CoreGraphics

/// User preferences (UserDefaults). Keys are shared with the SwiftUI settings view.
public enum Prefs {
    public enum Key {
        public static let placement = "placementPolicy"
        public static let fitPercent = "fitPercent"
        public static let allowUpscale = "allowUpscale"
        public static let offsetStacked = "offsetStackedWindows"
        public static let lastFrame = "lastWindowFrame"
        public static let wheelZooms = "scrollWheelZooms"
        public static let videoAutoplay = "videoAutoplay"
        public static let videoLoop = "videoLoop"
        public static let videoMuted = "videoMuted"
        public static let markupColor = "markupColor"
        public static let markupSize = "markupSize"
        public static let showMarkupOnOpen = "showMarkupOnOpen"
        public static let textFontSize = "textFontSize"
        public static let textMonospaced = "textMonospaced"
        public static let textWraps = "textWrapsLines"
        public static let openTogether = "openSeveralInOneWindow"
    }

    private static var store: UserDefaults { .standard }

    public static func registerDefaults() {
        store.register(defaults: [
            Key.placement: PlacementPolicy.centerOnMainDisplay.rawValue,
            Key.fitPercent: 80.0,
            Key.allowUpscale: false,
            Key.offsetStacked: true,
            Key.wheelZooms: true,
            Key.videoAutoplay: true,
            Key.videoLoop: false,
            Key.videoMuted: false,
            Key.markupSize: 1,
            Key.showMarkupOnOpen: true,
            Key.textFontSize: defaultTextSize,
            Key.textMonospaced: true,
            Key.textWraps: true,
            Key.openTogether: true,
        ])
    }

    public static var placement: PlacementPolicy {
        PlacementPolicy(rawValue: store.string(forKey: Key.placement) ?? "") ?? .centerOnMainDisplay
    }

    public static var fitFraction: CGFloat {
        CGFloat(min(max(store.double(forKey: Key.fitPercent), 30), 100)) / 100
    }

    public static var allowUpscale: Bool { store.bool(forKey: Key.allowUpscale) }
    public static var offsetStackedWindows: Bool { store.bool(forKey: Key.offsetStacked) }
    public static var wheelZooms: Bool { store.bool(forKey: Key.wheelZooms) }
    public static var showMarkupOnOpen: Bool { store.bool(forKey: Key.showMarkupOnOpen) }
    /// Several files opened at once share one window with a thumbnail sidebar (else a window each).
    public static var openSeveralInOneWindow: Bool { store.bool(forKey: Key.openTogether) }
    public static var videoAutoplay: Bool { store.bool(forKey: Key.videoAutoplay) }
    public static var videoLoop: Bool { store.bool(forKey: Key.videoLoop) }
    public static var videoMuted: Bool { store.bool(forKey: Key.videoMuted) }

    /// Text opens at this size until the user zooms; then the last zoom is remembered.
    public static let defaultTextSize: Double = 18

    public static var textFontSize: CGFloat {
        get { CGFloat(store.double(forKey: Key.textFontSize)) }
        set { store.set(Double(newValue), forKey: Key.textFontSize) }
    }

    public static var textMonospaced: Bool { store.bool(forKey: Key.textMonospaced) }
    public static var textWraps: Bool { store.bool(forKey: Key.textWraps) }

    public static var lastFrame: CGRect? {
        get {
            guard let s = store.string(forKey: Key.lastFrame) else { return nil }
            let r = NSRectFromString(s)
            return r.width > 0 && r.height > 0 ? r : nil
        }
        set { store.set(newValue.map { NSStringFromRect($0) }, forKey: Key.lastFrame) }
    }

    static func string(_ key: String) -> String? { store.string(forKey: key) }
    static func integer(_ key: String) -> Int { store.integer(forKey: key) }
    static func set(_ value: Any?, _ key: String) { store.set(value, forKey: key) }
}
