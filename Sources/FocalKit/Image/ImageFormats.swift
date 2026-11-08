import CoreGraphics
import Foundation

/// Formats macOS reads but won't write (SGI) or won't read at all (XBM), which Preview handles.

/// SGI image writer: ImageIO decodes SGI but has no encoder. Writes the uncompressed ("verbatim") form,
/// 8 bits per channel, RGB or RGBA, which every SGI reader accepts.
enum SGIEncoder {
    static func encode(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= Int(UInt16.max), h <= Int(UInt16.max) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let channels = hasAlpha ? 4 : 3
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var out = Data(count: 512)
        func put16(_ v: Int, at offset: Int) { out[offset] = UInt8(v >> 8 & 0xff); out[offset + 1] = UInt8(v & 0xff) }
        func put32(_ v: Int, at offset: Int) { for i in 0..<4 { out[offset + i] = UInt8(v >> (24 - 8 * i) & 0xff) } }
        put16(474, at: 0)        // magic
        out[2] = 0               // storage: verbatim
        out[3] = 1               // bytes per channel
        put16(3, at: 4)          // dimension: x, y and channels
        put16(w, at: 6)
        put16(h, at: 8)
        put16(channels, at: 10)
        put32(0, at: 12)         // pixmin
        put32(255, at: 16)       // pixmax
        // 20...103: dummy + image name (zeros), 104: colormap 0 (normal), rest of the header zero.

        // One plane per channel; each plane's rows run bottom to top (the context's rows run top to bottom).
        var body = [UInt8](repeating: 0, count: w * h * channels)
        var i = 0
        for c in 0..<channels {
            for y in 0..<h {
                let row = (h - 1 - y) * w * 4
                for x in 0..<w {
                    let p = row + x * 4
                    let a = Int(rgba[p + 3])
                    if c == 3 {
                        body[i] = UInt8(a)
                    } else {
                        let v = Int(rgba[p + c])   // premultiplied: undo it, SGI stores straight colour
                        body[i] = a == 0 ? 0 : UInt8(min(255, (v * 255 + a / 2) / a))
                    }
                    i += 1
                }
            }
        }
        out.append(contentsOf: body)
        return out
    }
}

/// X BitMap: a C source fragment (`#define x_width 16` … `static char x_bits[] = { 0x00, … }`). Bits run
/// least significant first, rows padded to whole bytes, 1 = foreground. Shown black on white, as Preview does.
/// The old X10 form stores 16-bit words (`short`), low byte first.
enum XBMDecoder {
    static func decode(_ data: Data) -> CGImage? {
        guard data.count < 16 << 20, let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8),
              let w = define(text, suffix: "_width"), let h = define(text, suffix: "_height"),
              w > 0, h > 0, w <= 32_768, h <= 32_768, let open = text.firstIndex(of: "{") else { return nil }
        let words = text[open...].matches(of: /0[xX]([0-9a-fA-F]{1,4})/).compactMap { Int($0.1, radix: 16) }
        let isX10 = text.contains("short")
        let bytes: [UInt8] = isX10 ? words.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8 & 0xff)] } : words.map { UInt8($0 & 0xff) }
        let rowBytes = (w + 7) / 8
        guard bytes.count >= rowBytes * h else { return nil }
        var gray = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w where bytes[y * rowBytes + x / 8] >> (x % 8) & 1 == 1 {
                gray[y * w + x] = 0
            }
        }
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    private static func define(_ text: String, suffix: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 3, parts[0] == "#define", parts[1].hasSuffix(suffix) { return Int(parts[2]) }
        }
        return nil
    }
}
