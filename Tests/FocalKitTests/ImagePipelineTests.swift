import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FocalKit

// MARK: helpers

private typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

/// White image with single-pixel marks at top-left-origin coordinates.
private func makeImage(_ w: Int, _ h: Int, marks: [(x: Int, y: Int, color: CGColor)] = [], clear: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if !clear {
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    for m in marks {
        ctx.setFillColor(m.color)
        ctx.fill(CGRect(x: m.x, y: h - 1 - m.y, width: 1, height: 1))
    }
    return ctx.makeImage()!
}

private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> RGBA {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let i = (y * img.width + x) * 4   // memory row 0 is the top row
    return (p[i], p[i + 1], p[i + 2], p[i + 3])
}

private func isRed(_ p: RGBA) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
private func isBlack(_ p: RGBA) -> Bool { p.r < 40 && p.g < 40 && p.b < 40 && p.a > 200 }
private func isWhite(_ p: RGBA) -> Bool { p.r > 230 && p.g > 230 && p.b > 230 && p.a > 230 }
private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

private func redact(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Annotation {
    Annotation(kind: .redact, points: [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)], color: .black, lineWidth: 0)
}

// MARK: rotation and crop

@Test func rotatingClockwiseMovesTopLeftToTopRight() throws {
    let img = makeImage(4, 2, marks: [(0, 0, red)])
    let r = try #require(ImageOps.rotate(img, clockwise: true))
    #expect((r.width, r.height) == (2, 4))
    #expect(isRed(pixel(r, 1, 0)))
    #expect(!isRed(pixel(r, 0, 0)))
}

@Test func rotatingCounterClockwiseMovesTopLeftToBottomLeft() throws {
    let img = makeImage(4, 2, marks: [(0, 0, red)])
    let r = try #require(ImageOps.rotate(img, clockwise: false))
    #expect(isRed(pixel(r, 0, 3)))
}

@Test func marksFollowTheImageWhenRotated() throws {
    let state = EditState(image: makeImage(100, 60), annotations: [redact(10, 10, 30, 20)])
    let before = try #require(Flattener.flatten(state))
    #expect(isBlack(pixel(before, 20, 15)))
    let rotated = try #require(state.rotated(clockwise: true))
    let after = try #require(Flattener.flatten(rotated))
    #expect((after.width, after.height) == (60, 100))
    // (20, 15) → (60 - 15, 20) = (45, 20)
    #expect(isBlack(pixel(after, 44, 20)))
    #expect(isWhite(pixel(after, 20, 15)))
}

@Test func cropKeepsMarksInPlace() throws {
    let state = EditState(image: makeImage(100, 60, marks: [(52, 22, red)]), annotations: [redact(55, 25, 60, 30)])
        .cropped(to: CGRect(x: 50, y: 20, width: 30, height: 30))
    let out = try #require(Flattener.flatten(state))
    #expect((out.width, out.height) == (30, 30))
    #expect(isRed(pixel(out, 2, 2)), "image pixel (52,22) lands at (2,2)")
    #expect(isBlack(pixel(out, 7, 7)), "mark (55…60, 25…30) lands at (5…10)")
    #expect(isWhite(pixel(out, 20, 20)))
}

@Test func cropCannotGrowPastTheCurrentCrop() {
    let s = EditState(image: makeImage(100, 60)).cropped(to: CGRect(x: 10, y: 10, width: 50, height: 30))
    #expect(s.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200)).crop == CGRect(x: 10, y: 10, width: 50, height: 30))
}

@Test func jpegBackgroundFillsTransparency() throws {
    let out = try #require(Flattener.flatten(EditState(image: makeImage(8, 8, clear: true)),
                                             background: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)))
    #expect(isWhite(pixel(out, 3, 3)))
}

@Test func everyMarkKindRenders() throws {
    let pts = [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 50)]
    let marks = AnnotationKind.allCases.map {
        Annotation(kind: $0, points: $0 == .pen || $0 == .highlighter ? [pts[0], CGPoint(x: 40, y: 30), pts[1]] : pts,
                   color: .red, lineWidth: 4, text: "Note", fontSize: 14, number: 3)
    }
    let out = try #require(Flattener.flatten(EditState(image: makeImage(100, 60), annotations: marks)))
    #expect(isRed(pixel(out, 45, 30)) || isBlack(pixel(out, 45, 30)), "something was painted along the strokes")
}

@Test func arrowPaintsItsTip() throws {
    let arrow = Annotation(kind: .arrow, points: [CGPoint(x: 5, y: 30), CGPoint(x: 90, y: 30)], color: .red, lineWidth: 4)
    let out = try #require(Flattener.flatten(EditState(image: makeImage(100, 60), annotations: [arrow])))
    #expect(isRed(pixel(out, 85, 30)))
    #expect(isRed(pixel(out, 40, 30)))
    #expect(isWhite(pixel(out, 40, 45)))
}

// MARK: loading and saving

@Test func retinaScreenshotDPISurvivesASave() throws {
    let data = try ImageExporter.encode(makeImage(200, 100), as: .png, dpi: CGSize(width: 144, height: 144), sourceProperties: [:])
    let info = try ImageLoader.probe(try ImageLoader.source(data: data))
    #expect(info.pixelSize == CGSize(width: 200, height: 100))
    #expect(info.pixelsPerPoint == 2)
    #expect(info.pointSize == CGSize(width: 100, height: 50))
}

@Test func printDPIDoesNotShrinkPhotos() {
    #expect(ImageInfo.retinaScale(dpi: 300) == 1)
    #expect(ImageInfo.retinaScale(dpi: 72) == 1)
    #expect(ImageInfo.retinaScale(dpi: 216) == 3)
}

@Test func exifOrientationIsAppliedOnLoad() throws {
    // A 40×20 sensor image tagged "rotate 90° CW to display" (6) must come out 20×40, upright.
    let img = makeImage(40, 20, marks: [(0, 0, red)])
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    // Typed explicitly: an untyped literal infers Double for both values and ImageIO drops a 6.0 orientation.
    let props: [CFString: Any] = [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1.0]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    let src = try ImageLoader.source(data: data as Data)
    let info = try ImageLoader.probe(src)
    #expect(info.pixelSize == CGSize(width: 20, height: 40))
    let decoded = try ImageLoader.decode(src, info: info)
    #expect((decoded.width, decoded.height) == (20, 40))
    #expect(isRed(pixel(decoded, 19, 0)) || isRed(pixel(decoded, 18, 1)), "stored top-left shows at top-right")
}

@Test func savedJPEGIsUprightAndKeepsDimensions() throws {
    let data = try ImageExporter.encode(makeImage(30, 10), as: .jpeg, dpi: CGSize(width: 72, height: 72),
                                        sourceProperties: [kCGImagePropertyOrientation: 6])
    let info = try ImageLoader.probe(try ImageLoader.source(data: data))
    #expect(info.orientation == .up)
    #expect(info.pixelSize == CGSize(width: 30, height: 10))
}

// MARK: folder navigation

@Test func siblingsAreViewableFilesInFinderOrder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focal-nav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["img10.png", "img2.png", "a.jpg", "clip.mov", "notes.txt", ".hidden.png"] {
        try Data().write(to: dir.appendingPathComponent(name))
    }
    let files = FolderNavigator.siblings(of: dir.appendingPathComponent("img2.png")).map(\.lastPathComponent)
    #expect(files == ["a.jpg", "clip.mov", "img2.png", "img10.png", "notes.txt"], "text files are viewable too")
    let urls = FolderNavigator.siblings(of: dir.appendingPathComponent("a.jpg"))
    #expect(FolderNavigator.neighbor(of: dir.appendingPathComponent("img2.png"), in: urls, offset: 1)?.lastPathComponent == "img10.png")
    #expect(FolderNavigator.neighbor(of: dir.appendingPathComponent("img10.png"), in: urls, offset: 1)?.lastPathComponent == "notes.txt")
    #expect(FolderNavigator.neighbor(of: dir.appendingPathComponent("notes.txt"), in: urls, offset: 1) == nil, "no wrap-around past the last file")
}

@Test func filesOpenedTogetherAreListedViewableOnlyInFinderOrder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focal-set-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let names = ["img10.png", "img2.png", "clip.mp4", "notes.md", "data.json", "readme.txt"]
    for name in names { try Data().write(to: dir.appendingPathComponent(name)) }
    let listed = FolderNavigator.browsable(names.map { dir.appendingPathComponent($0) }).map(\.lastPathComponent)
    // JSON isn't something Focal shows; numbers sort the way Finder sorts them (img2 before img10).
    #expect(listed == ["clip.mp4", "img2.png", "img10.png", "notes.md", "readme.txt"])
}

@Test func aFolderOpensAsItsViewableFilesAndPackagesAreFiles() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("focal-folder-\(UUID().uuidString)")
    try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    for name in ["b.png", "a10.txt", "a2.txt", "data.json", "sub/inner.png"] { try Data().write(to: dir.appendingPathComponent(name)) }
    let rtfd = dir.appendingPathComponent("letter.rtfd")
    try NSAttributedString(string: "hi").rtfdFileWrapper(from: NSRange(location: 0, length: 2))?
        .write(to: rtfd, options: [], originalContentsURL: nil)
    // A folder: its viewable files, RTFD packages included, subfolders and unviewable files left out.
    let listed = try #require(FolderNavigator.folderToBrowse(dir)).map(\.lastPathComponent)
    #expect(listed == ["a2.txt", "a10.txt", "b.png", "letter.rtfd"])
    #expect(FolderNavigator.folderToBrowse(rtfd) == nil, "an RTFD is a document, not a folder")
    #expect(FolderNavigator.folderToBrowse(dir.appendingPathComponent("b.png")) == nil)
    // Stepping with ⌘] now reaches the RTFD too (it was skipped as a directory).
    #expect(FolderNavigator.siblings(of: dir.appendingPathComponent("b.png")).map(\.lastPathComponent).last == "letter.rtfd")
}
