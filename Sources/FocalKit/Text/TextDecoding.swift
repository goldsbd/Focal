import Foundation

public enum LineEnding: String, Sendable {
    case lf = "LF", crlf = "CRLF", cr = "CR"
}

/// Turns file bytes into text: BOMs first, then UTF-8, then Foundation's encoding detection
/// (Windows-1252 / Mac Roman for old files), and finally lossy UTF-8 so a file always opens.
/// `encode` goes back the other way for saving, in the file's own encoding and line endings.
public enum TextDecoding {
    public struct Result: Sendable {
        public var text: String
        public var encodingName: String
        public var encoding: String.Encoding = .utf8
        public var hasBOM = false
        public var lineEnding: LineEnding = .lf
    }

    public static func decode(_ data: Data) -> Result {
        let boms: [([UInt8], String.Encoding)] = [([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian),
                                                  ([0xFE, 0xFF], .utf16BigEndian)]
        for (bom, encoding) in boms where data.starts(with: bom) {
            if let s = String(data: data.dropFirst(bom.count), encoding: encoding) {
                return Result(text: s, encodingName: String.localizedName(of: encoding), encoding: encoding,
                              hasBOM: true, lineEnding: lineEnding(of: s))
            }
        }
        if let s = String(data: data, encoding: .utf8) {
            return Result(text: s, encodingName: String.localizedName(of: .utf8), encoding: .utf8, lineEnding: lineEnding(of: s))
        }
        var converted: NSString?
        var lossy: ObjCBool = false
        let suggested = [String.Encoding.windowsCP1252.rawValue, String.Encoding.macOSRoman.rawValue]
        let raw = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: suggested],
                                          convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, let converted, !lossy.boolValue {
            let encoding = String.Encoding(rawValue: raw)
            let s = converted as String
            return Result(text: s, encodingName: String.localizedName(of: encoding), encoding: encoding, lineEnding: lineEnding(of: s))
        }
        let s = String(decoding: data, as: UTF8.self)
        return Result(text: s, encodingName: "UTF-8 (invalid bytes replaced)", encoding: .utf8, lineEnding: lineEnding(of: s))
    }

    /// The file's dominant line ending (from the first 256 KB).
    public static func lineEnding(of text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var previousCR = false
        for byte in text.utf8.prefix(262_144) {
            if byte == 0x0A {
                if previousCR { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if byte == 0x0D {
                cr += 1
            }
            previousCR = byte == 0x0D
        }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }

    public struct Encoded: Sendable {
        public var data: Data
        public var encoding: String.Encoding
        /// True when the original encoding couldn't hold the text and UTF-8 was used instead.
        public var fellBackToUTF8: Bool
    }

    /// Bytes for saving: every line break becomes the file's own ending (typing Return inserts LF, which
    /// would otherwise leave a CRLF file mixed), the original encoding and BOM are kept, and if that encoding
    /// can't represent the text, UTF-8 is used rather than dropping characters.
    public static func encode(_ text: String, encoding: String.Encoding, bom: Bool, lineEnding: LineEnding) -> Encoded {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let normalized: String = switch lineEnding {
        case .lf: unified
        case .crlf: unified.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: unified.replacingOccurrences(of: "\n", with: "\r")
        }
        if let body = normalized.data(using: encoding, allowLossyConversion: false) {
            return Encoded(data: (bom ? byteOrderMark(encoding) : Data()) + body, encoding: encoding, fellBackToUTF8: false)
        }
        return Encoded(data: Data(normalized.utf8), encoding: .utf8, fellBackToUTF8: true)
    }

    static func byteOrderMark(_ encoding: String.Encoding) -> Data {
        switch encoding {
        case .utf8: Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian: Data([0xFE, 0xFF])
        default: Data()
        }
    }

    /// Line count with the same rules as `measure` (a final line without a break counts; CRLF is one break),
    /// scanning UTF-16 units instead of grapheme clusters so it stays fast on multi-megabyte text after edits.
    public static func lineCount(_ text: String) -> Int {
        var lines = 0
        var last: UInt16 = 0x0A
        var previousCR = false
        for unit in text.utf16 {
            if unit == 0x0D || (unit == 0x0A && !previousCR) { lines += 1 }
            previousCR = unit == 0x0D
            last = unit
        }
        if last != 0x0A && last != 0x0D { lines += 1 }
        return lines
    }

    /// Line count and longest line (in characters, capped) for sizing the window, in one pass.
    public static func measure(_ text: String, cap: Int = 400) -> (lines: Int, longest: Int) {
        var lines = 0, longest = 0, run = 0
        var last: Character?
        for ch in text {
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                lines += 1
                longest = max(longest, run)
                run = 0
            } else if run < cap {
                run += 1
            }
            last = ch
        }
        if let last, last != "\n", last != "\r\n", last != "\r" { lines += 1 }
        return (lines, max(longest, run))
    }
}
