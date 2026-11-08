import AppKit

/// Everything an image edit can change. The decoded pixels stay untouched; rotation produces a new
/// base image, crop and marks are kept separately and only burned in when saving or copying, so marks
/// stay editable after a save and re-saving never draws them twice.
public struct EditState: @unchecked Sendable {   // CGImage is immutable; safe to share.
    public var image: CGImage
    /// In image pixels, top-left origin; nil means the whole image.
    public var crop: CGRect?
    public var annotations: [Annotation]

    public init(image: CGImage, crop: CGRect? = nil, annotations: [Annotation] = []) {
        self.image = image
        self.crop = crop
        self.annotations = annotations
    }

    public var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    public var canvasRect: CGRect { crop ?? CGRect(origin: .zero, size: imageSize) }

    public func rotated(clockwise: Bool) -> EditState? {
        guard let rotatedImage = ImageOps.rotate(image, clockwise: clockwise) else { return nil }
        let size = imageSize
        return EditState(image: rotatedImage,
                         crop: crop.map { Geometry.rotate($0, clockwise: clockwise, imageSize: size) },
                         annotations: annotations.map { $0.rotated(clockwise: clockwise, imageSize: size) })
    }

    /// Crop to `rect` (image pixels), never outside what is visible now.
    public func cropped(to rect: CGRect) -> EditState {
        var s = self
        let r = rect.intersection(canvasRect).integral.intersection(CGRect(origin: .zero, size: imageSize))
        s.crop = r.isNull || r.isEmpty ? crop : r
        return s
    }
}

public enum ImageOps {
    /// A bitmap context matching the image's color space and depth (8 or 16 bits per channel).
    public static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb { space = cs } else { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = makeContext(width: h, height: w, like: image) else { return nil }
        ctx.interpolationQuality = .none
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Downscaled copy for display when an image exceeds what one GPU texture can hold.
    public static func displayImage(_ image: CGImage, maxPixel: Int = 16_384) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = makeContext(width: w, height: h, like: image) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

public enum Flattener {
    /// Burn crop and marks into a new image. `background` fills transparent areas (used for JPEG).
    public static func flatten(_ state: EditState, background: CGColor? = nil) -> CGImage? {
        let r = state.canvasRect.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0, let ctx = ImageOps.makeContext(width: w, height: h, like: state.image) else { return nil }
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Bottom-left CG space: place the image so the crop's top-left lands on the context's top-left.
        let imageHeight = CGFloat(state.image.height)
        ctx.interpolationQuality = .none
        ctx.draw(state.image, in: CGRect(x: -r.minX, y: r.maxY - imageHeight,
                                         width: CGFloat(state.image.width), height: imageHeight))
        if !state.annotations.isEmpty {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -r.minX, y: -r.minY)
            ctx.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            AnnotationRenderer.draw(state.annotations, in: ctx)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }
}
