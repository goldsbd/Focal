import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExporterError: LocalizedError, Equatable {
    case unsupportedType(String)
    case encodeFailed
    case iconSize(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let t): "Saving as \(t) isn't supported."
        case .encodeFailed: "The image couldn't be encoded."
        case .iconSize(let w, let h):
            "An icon must be square, 16, 32, 64, 128, 256, 512 or 1024 pixels; this image is \(w) × \(h). Use Save As to keep it as PNG."
        }
    }
}

public enum ImageExporter {
    /// Encode, carrying over the source's camera/GPS/IPTC metadata and its DPI (keeps Retina
    /// screenshots at 144 dpi so they still open at their true size).
    public static func encode(_ image: CGImage, as type: UTType, dpi: CGSize, sourceProperties: [CFString: Any]) throws -> Data {
        if type.conforms(to: UTType("com.sgi.sgi-image")!) {   // ImageIO reads SGI but can't write it
            guard let data = SGIEncoder.encode(image) else { throw ImageExporterError.encodeFailed }
            return data
        }
        if type.conforms(to: .icns) {
            guard image.width == image.height, iconSizes.contains(image.width) else {
                throw ImageExporterError.iconSize(width: image.width, height: image.height)
            }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw ImageExporterError.unsupportedType(type.localizedDescription ?? type.identifier) }
        CGImageDestinationAddImage(dest, image, metadata(from: sourceProperties, dpi: dpi, type: type,
                                                         size: CGSize(width: image.width, height: image.height)) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageExporterError.encodeFailed }
        return data as Data
    }

    /// Formats ImageIO writes with several frames.
    static let animatedTypes: [UTType] = [.gif, .png, UTType("public.heics")!]

    /// Every frame copied untouched, with its timing and the file's loop count.
    static func copyFrames(from src: CGImageSource, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let count = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, count, nil)
        else { throw ImageExporterError.unsupportedType(type.localizedDescription ?? type.identifier) }
        if let props = CGImageSourceCopyProperties(src, nil) { CGImageDestinationSetProperties(dest, props) }
        for i in 0..<count { CGImageDestinationAddImageFromSource(dest, src, i, nil) }
        guard CGImageDestinationFinalize(dest) else { throw ImageExporterError.encodeFailed }
        return data as Data
    }

    /// Formats that hold several pages (a TIFF's pages, an icon's sizes, a PDF's pages).
    static let multiPageTypes: [UTType] = [.tiff, .icns, .ico, .heic, .pdf]

    /// Every page of `src`, the edited ones replaced and the rest copied untouched (their own metadata kept).
    static func encodePages(from src: CGImageSource, replacing edited: [Int: CGImage], as type: UTType, dpi: CGSize) throws -> Data {
        guard multiPageTypes.contains(where: type.conforms(to:)) else {
            throw ImageExporterError.unsupportedType(type.localizedDescription ?? type.identifier)
        }
        let count = CGImageSourceGetCount(src)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, count, nil)
        else { throw ImageExporterError.unsupportedType(type.localizedDescription ?? type.identifier) }
        for i in 0..<count {
            if let image = edited[i] {
                if type.conforms(to: .icns), image.width != image.height || !iconSizes.contains(image.width) {
                    throw ImageExporterError.iconSize(width: image.width, height: image.height)
                }
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
                CGImageDestinationAddImage(dest, image, metadata(from: props, dpi: dpi, type: type,
                                                                 size: CGSize(width: image.width, height: image.height)) as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(dest, src, i, nil)
            }
        }
        guard CGImageDestinationFinalize(dest) else { throw ImageExporterError.encodeFailed }
        return data as Data
    }

    static let iconSizes: Set<Int> = [16, 32, 64, 128, 256, 512, 1024]

    static func metadata(from src: [CFString: Any], dpi: CGSize, type: UTType, size: CGSize) -> [CFString: Any] {
        var out: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,   // pixels are already upright
            kCGImagePropertyDPIWidth: dpi.width,
            kCGImagePropertyDPIHeight: dpi.height,
        ]
        if var exif = src[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = Int(size.width)
            exif[kCGImagePropertyExifPixelYDimension] = Int(size.height)
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = src[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = src[key] { out[key] = v }
        }
        if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
            out[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        return out
    }
}
