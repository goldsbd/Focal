import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Header facts about an image, read without decoding pixels (so the window can be sized at once).
public struct ImageInfo: @unchecked Sendable {   // immutable after creation
    /// Size as displayed (EXIF orientation applied).
    public var pixelSize: CGSize
    public var dpi: CGSize
    public var orientation: CGImagePropertyOrientation
    public var typeIdentifier: String?
    public var frameCount: Int
    public var isAnimated: Bool
    public var properties: [CFString: Any]

    public static let empty = ImageInfo(pixelSize: .zero, dpi: CGSize(width: 72, height: 72), orientation: .up,
                                        typeIdentifier: nil, frameCount: 0, isAnimated: false, properties: [:])

    /// 2 for Retina screenshots (144 dpi), 3 for @3x; 1 otherwise. Print DPIs (300…) are ignored,
    /// so a camera JPEG tagged 300 dpi still shows one image pixel per point at 100 %.
    public var pixelsPerPoint: CGFloat { Self.retinaScale(dpi: dpi.width) }
    public var pointSize: CGSize {
        CGSize(width: pixelSize.width / pixelsPerPoint, height: pixelSize.height / pixelsPerPoint)
    }

    public static func retinaScale(dpi: CGFloat) -> CGFloat {
        for scale in [2.0, 3.0] where abs(dpi - 72 * scale) < 1 { return scale }
        return 1
    }
}

public enum ImageLoaderError: LocalizedError {
    case unreadable
    case noImage
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file couldn't be read as an image."
        case .noImage: "The file doesn't contain an image macOS can decode."
        case .decodeFailed: "The image couldn't be decoded."
        }
    }
}

public enum ImageLoader {
    public static func source(url: URL) throws -> CGImageSource {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageLoaderError.unreadable }
        return s
    }

    public static func source(data: Data) throws -> CGImageSource {
        guard let s = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageLoaderError.unreadable }
        return s
    }

    /// Pages to step through: a TIFF's pages, an icon's sizes. An animation's frames play instead, so it has one.
    public static func pageCount(_ src: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(src)
        guard count > 1, let info = try? probe(src) else { return max(count, 1) }
        return info.isAnimated ? 1 : count
    }

    public static func probe(_ src: CGImageSource, index: Int = 0) throws -> ImageInfo {
        let count = CGImageSourceGetCount(src)
        guard count > index, let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        else { throw ImageLoaderError.noImage }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { throw ImageLoaderError.noImage }
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        let swaps: Set<CGImagePropertyOrientation> = [.left, .right, .leftMirrored, .rightMirrored]
        let size = swaps.contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let dpiX = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let dpiY = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? dpiX
        let type = CGImageSourceGetType(src) as String?
        let animatable: [UTType] = [.gif, .png, .webP, UTType("public.heics")].compactMap { $0 }
        let animated = count > 1 && type.flatMap(UTType.init).map { t in animatable.contains { t.conforms(to: $0) } } == true
        return ImageInfo(pixelSize: size, dpi: CGSize(width: dpiX, height: dpiY), orientation: orientation,
                         typeIdentifier: type, frameCount: count, isAnimated: animated, properties: props)
    }

    /// Full-resolution decode, done off the main thread. Orientation is baked in so pixels are upright.
    public static func decode(_ src: CGImageSource, info: ImageInfo, index: Int = 0) throws -> CGImage {
        if info.orientation == .up {
            guard let image = CGImageSourceCreateImageAtIndex(src, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw ImageLoaderError.decodeFailed }
            return image
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(info.pixelSize.width, info.pixelSize.height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
        else { throw ImageLoaderError.decodeFailed }
        return image
    }

    /// A small upright copy of one page, for the page strip.
    public static func thumbnail(_ src: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// Formats ImageIO can't open: X BitMap (decoded here), then whatever AppKit can draw (SVG, EPS).
    public static func decodeFallback(url: URL) -> (image: CGImage, info: ImageInfo)? {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), let xbm = XBMDecoder.decode(data) {
            var info = ImageInfo.empty
            info.pixelSize = CGSize(width: xbm.width, height: xbm.height)
            info.typeIdentifier = "public.xbitmap-image"
            info.frameCount = 1
            return (xbm, info)
        }
        return rasterizeWithAppKit(url: url)
    }

    /// Formats ImageIO can't open but AppKit can (SVG, EPS): rasterize at 2x.
    public static func rasterizeWithAppKit(url: URL) -> (image: CGImage, info: ImageInfo)? {
        guard let ns = NSImage(contentsOf: url), ns.size.width > 0, ns.size.height > 0 else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: ns.size.width * 2, height: ns.size.height * 2))
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var info = ImageInfo.empty
        info.pixelSize = CGSize(width: cg.width, height: cg.height)
        info.dpi = CGSize(width: 144, height: 144)
        info.typeIdentifier = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
        info.frameCount = 1
        return (cg, info)
    }
}
