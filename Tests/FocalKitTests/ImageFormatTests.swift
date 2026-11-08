import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FocalKit

/// RGBA bytes of an image, top row first.
private func pixels(_ image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return out
}

private func image(width: Int, height: Int, rgba: [UInt8]) -> CGImage {
    var data = rgba
    let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@Test func sgiSavesAndMacOSReadsItBack() throws {
    // 3 x 2: red green blue / white black grey (top row first), opaque.
    let rgba: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255,  255,255,255,255, 0,0,0,255, 128,128,128,255]
    let data = try ImageExporter.encode(image(width: 3, height: 2, rgba: rgba), as: UTType("com.sgi.sgi-image")!,
                                        dpi: CGSize(width: 72, height: 72), sourceProperties: [:])
    let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetType(src) as String? == "com.sgi.sgi-image")
    let back = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(back.width == 3 && back.height == 2)
    #expect(pixels(back) == rgba, "rows must not come back upside down (SGI counts rows from the bottom)")
}

@Test func xbmDecodesBitsLeastSignificantFirst() throws {
    let text = """
    #define tiny_width 10
    #define tiny_height 2
    static unsigned char tiny_bits[] = {
       0x01, 0x02, 0xff, 0x03 };
    """
    let img = try #require(XBMDecoder.decode(Data(text.utf8)))
    #expect(img.width == 10 && img.height == 2)
    let px = pixels(img)
    func black(_ x: Int, _ y: Int) -> Bool { px[(y * 10 + x) * 4] < 128 }
    // Row 0: 0x01 → pixel 0 set; 0x02 → pixel 9 (bit 1 of the second byte) set.
    #expect((0..<10).map { black($0, 0) } == [true, false, false, false, false, false, false, false, false, true])
    // Row 1: 0xff, 0x03 → all ten set.
    #expect((0..<10).allSatisfy { black($0, 1) })
    #expect(XBMDecoder.decode(Data("not an xbm".utf8)) == nil)
}

@Test func iconsMustBeAStandardSquareSize() throws {
    let icns = UTType("com.apple.icns")!
    let dpi = CGSize(width: 72, height: 72)
    let ok = image(width: 256, height: 256, rgba: [UInt8](repeating: 200, count: 256 * 256 * 4))
    #expect(try ImageExporter.encode(ok, as: icns, dpi: dpi, sourceProperties: [:]).count > 0)
    let odd = image(width: 100, height: 80, rgba: [UInt8](repeating: 200, count: 100 * 80 * 4))
    #expect(throws: ImageExporterError.iconSize(width: 100, height: 80)) {
        try ImageExporter.encode(odd, as: icns, dpi: dpi, sourceProperties: [:])
    }
}

@Test func exportsToPDFJPEG2000AndOpenEXR() throws {
    let img = image(width: 288, height: 144, rgba: [UInt8](repeating: 180, count: 288 * 144 * 4))
    for id in ["com.adobe.pdf", "public.jpeg-2000", "com.ilm.openexr-image"] {
        let data = try ImageExporter.encode(img, as: UTType(id)!, dpi: CGSize(width: 144, height: 144), sourceProperties: [:])
        #expect(data.count > 0, "\(id)")
    }
    // A 144 dpi picture makes a page of its point size (Retina screenshots print at their true size).
    let pdf = try ImageExporter.encode(img, as: .pdf, dpi: CGSize(width: 144, height: 144), sourceProperties: [:])
    let page = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.page(at: 1))
    #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 144, height: 72))
}

/// A TIFF with two pages of different sizes and colours.
private func twoPageTIFF() -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.tiff.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(dest, image(width: 4, height: 3, rgba: [UInt8](repeating: 0, count: 48).enumerated().map { $0.offset % 4 == 3 ? 255 : ($0.offset % 4 == 2 ? 255 : 0) }), nil)  // blue
    CGImageDestinationAddImage(dest, image(width: 2, height: 2, rgba: [0,255,0,255, 0,255,0,255, 0,255,0,255, 0,255,0,255]), nil)              // green
    CGImageDestinationFinalize(dest)
    return data as Data
}

@Test func eachPageOfAMultiPageImageProbesItsOwnSize() throws {
    let src = try ImageLoader.source(data: twoPageTIFF())
    #expect(ImageLoader.pageCount(src) == 2)
    #expect(try ImageLoader.probe(src, index: 0).pixelSize == CGSize(width: 4, height: 3))
    #expect(try ImageLoader.probe(src, index: 1).pixelSize == CGSize(width: 2, height: 2))
    #expect(try ImageLoader.decode(src, info: ImageLoader.probe(src, index: 1), index: 1).width == 2)
}

@Test func savingOneEditedPageKeepsTheOthersUntouched() throws {
    let src = try ImageLoader.source(data: twoPageTIFF())
    let red = image(width: 2, height: 2, rgba: [255,0,0,255, 255,0,0,255, 255,0,0,255, 255,0,0,255])
    let out = try ImageExporter.encodePages(from: src, replacing: [1: red], as: .tiff, dpi: CGSize(width: 72, height: 72))
    let back = try ImageLoader.source(data: out)
    #expect(CGImageSourceGetCount(back) == 2, "no page lost")
    let page0 = try #require(CGImageSourceCreateImageAtIndex(back, 0, nil))
    let original0 = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(pixels(page0) == pixels(original0), "the page that wasn't edited is copied as it was")
    let page1 = try #require(CGImageSourceCreateImageAtIndex(back, 1, nil))
    #expect(Array(pixels(page1).prefix(4)) == [255, 0, 0, 255], "the edited page is written")
    // To a single-image format only the page showing can go: that's the caller's choice, not encodePages'.
    #expect(throws: ImageExporterError.self) {
        try ImageExporter.encodePages(from: src, replacing: [:], as: .jpeg, dpi: CGSize(width: 72, height: 72))
    }
}
