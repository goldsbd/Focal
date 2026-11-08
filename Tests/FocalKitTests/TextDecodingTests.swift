import Foundation
import Testing
@testable import FocalKit

@Test func plainUTF8Decodes() {
    let r = TextDecoding.decode(Data("héllo ✓".utf8))
    #expect(r.text == "héllo ✓")
    #expect(r.encodingName.contains("UTF-8"))
}

@Test func utf8ByteOrderMarkIsDropped() {
    let r = TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8))
    #expect(r.text == "abc")
}

@Test func utf16LittleEndianWithBOMDecodes() {
    let r = TextDecoding.decode(Data([0xFF, 0xFE]) + "Hi ✓".data(using: .utf16LittleEndian)!)
    #expect(r.text == "Hi ✓")
}

@Test func windows1252FallsBackCorrectly() {
    // "café — ok" in Windows-1252: é = E9, em dash = 97. Not valid UTF-8.
    let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x20, 0x97, 0x20, 0x6F, 0x6B]
    let r = TextDecoding.decode(Data(bytes))
    #expect(r.text == "café — ok")
}

@Test func measureCountsLinesAndLongestLine() {
    #expect(TextDecoding.measure("ab\nabcd\n") == (2, 4))
    #expect(TextDecoding.measure("ab\r\nabcdef") == (2, 6))
    #expect(TextDecoding.measure("") == (0, 0))
    #expect(TextDecoding.measure(String(repeating: "x", count: 1000), cap: 400) == (1, 400))
}

// MARK: saving

@Test func lineEndingIsDetected() {
    #expect(TextDecoding.lineEnding(of: "a\r\nb\r\nc") == .crlf)
    #expect(TextDecoding.lineEnding(of: "a\nb\nc") == .lf)
    #expect(TextDecoding.lineEnding(of: "a\rb\rc") == .cr)
    #expect(TextDecoding.lineEnding(of: "no breaks") == .lf)
}

@Test func savingACRLFFileKeepsCRLFEvenForNewlyTypedLines() {
    // The editor inserts "\n" for Return; the file must not end up with mixed endings.
    let e = TextDecoding.encode("one\r\ntwo\nthree\n", encoding: .utf8, bom: false, lineEnding: .crlf)
    #expect(e.data == Data("one\r\ntwo\r\nthree\r\n".utf8))
    #expect(!e.fellBackToUTF8)
}

@Test func windows1252RoundTripsInItsOwnEncoding() {
    let original: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A]   // "café\n"
    let decoded = TextDecoding.decode(Data(original))
    let e = TextDecoding.encode(decoded.text, encoding: decoded.encoding, bom: decoded.hasBOM, lineEnding: decoded.lineEnding)
    #expect(e.data == Data(original))
}

@Test func unrepresentableCharactersFallBackToUTF8InsteadOfBeingDropped() {
    let e = TextDecoding.encode("café ✓", encoding: .windowsCP1252, bom: false, lineEnding: .lf)
    #expect(e.fellBackToUTF8)
    #expect(String(data: e.data, encoding: .utf8) == "café ✓")
}

@Test func byteOrderMarksArePreserved() {
    let src = Data([0xFF, 0xFE]) + "Hi\r\n".data(using: .utf16LittleEndian)!
    let d = TextDecoding.decode(src)
    #expect(d.hasBOM && d.encoding == .utf16LittleEndian && d.lineEnding == .crlf)
    let e = TextDecoding.encode(d.text + "more\r\n", encoding: d.encoding, bom: d.hasBOM, lineEnding: d.lineEnding)
    #expect(e.data == Data([0xFF, 0xFE]) + "Hi\r\nmore\r\n".data(using: .utf16LittleEndian)!)
}

@Test func fastLineCountMatchesMeasure() {
    for sample in ["", "a", "a\n", "a\nb", "a\r\nb\r\n", "a\rb", "\n\n", "x\r\n\r\ny", "café ✓\n👍🏽"] {
        #expect(TextDecoding.lineCount(sample) == TextDecoding.measure(sample).lines, "\(sample.debugDescription)")
    }
}
