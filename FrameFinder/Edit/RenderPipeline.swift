import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

struct RenderSource {
    let url: URL
    let kind: ShotSource.Kind
    let rotation: PhotoRotation
    let crop: CGRect?

    init?(record: ShotRecord, store: ShotStore) {
        guard let source = record.source,
              FileManager.default.fileExists(atPath: store.url(for: source.file).path) else { return nil }
        url = store.url(for: source.file)
        kind = source.kind
        if source.precropped == true {
            rotation = .none
            crop = nil
        } else {
            rotation = record.rotation ?? .none
            crop = record.crop
        }
    }
}

enum RenderPipeline {
    static let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    static func render(_ source: RenderSource, develop: DevelopParams, color: ColorParams?,
                       crop: Bool = true, maxSide: CGFloat?, draft: Bool) -> CIImage? {
        let cropRect = crop ? source.crop : nil
        guard var image = load(source, develop: develop, cropRect: cropRect, maxSide: maxSide, draft: draft) else { return nil }
        image = PhotoProcessor.atOrigin(PhotoProcessor.oriented(image, source.rotation))
        if let r = cropRect?.intersection(.unit), !r.isNull, r.width > 0.02, r.height > 0.02 {
            let e = image.extent
            let rect = CGRect(x: e.minX + r.minX * e.width,
                              y: e.minY + (1 - r.maxY) * e.height,
                              width: r.width * e.width,
                              height: r.height * e.height).integral.intersection(e)
            image = PhotoProcessor.atOrigin(image.cropped(to: rect))
        }
        if let maxSide, max(image.extent.width, image.extent.height) > maxSide * 1.05 {
            image = PhotoProcessor.scaled(image, maxSide: maxSide)
        }
        image = tone(image, develop: develop, flatCurve: develop.flat)
        if let color { image = LookLibrary.apply(color, to: image) }
        return PhotoProcessor.atOrigin(image)
    }

    static func uiImage(_ image: CIImage) -> UIImage? {
        guard let cg = PhotoProcessor.context.createCGImage(image, from: image.extent.integral,
                                                            format: .RGBA8, colorSpace: displayColorSpace) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func encode(_ image: CIImage, source: RenderSource?, quality: Double) -> Data? {
        var metadata: [String: Any] = [:]
        if let source, let src = CGImageSourceCreateWithURL(source.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            metadata = props
        }
        return PhotoProcessor.encode(image, colorSpace: displayColorSpace, metadata: metadata, quality: quality)
    }

    private static func load(_ source: RenderSource, develop: DevelopParams, cropRect: CGRect?,
                             maxSide: CGFloat?, draft: Bool) -> CIImage? {
        let cropFraction = cropRect.map { max($0.width, $0.height) } ?? 1
        switch source.kind {
        case .proRAW:
            guard let filter = CIRAWFilter(imageURL: source.url) else { return nil }
            let native = filter.nativeSize
            if let maxSide, native.width > 0 {
                let longest = max(native.width, native.height) * cropFraction
                filter.scaleFactor = Float(min(1, maxSide / max(longest, 1)))
            }
            filter.isDraftModeEnabled = draft
            filter.orientation = .up
            filter.exposure = Float(develop.exposure)
            if develop.temperature != 0 {
                filter.neutralTemperature = min(max(filter.neutralTemperature + Float(develop.temperature * 2000), 2000), 50000)
            }
            if develop.tint != 0 {
                filter.neutralTint = min(max(filter.neutralTint + Float(develop.tint * 50), -150), 150)
            }
            if develop.flat {
                filter.boostAmount = 0
                if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
            }
            if filter.isHighlightRecoverySupported { filter.isHighlightRecoveryEnabled = true }
            guard let output = filter.outputImage else { return nil }
            return output.oriented(exifOrientation(of: source.url))
        case .heic:
            guard var image = CIImage(contentsOf: source.url, options: [.applyOrientationProperty: true]) else { return nil }
            if let maxSide {
                let longest = max(image.extent.width, image.extent.height) * cropFraction
                if longest > maxSide * 1.05 {
                    let s = maxSide / longest
                    image = PhotoProcessor.scaled(image, maxSide: max(image.extent.width, image.extent.height) * s)
                }
            }
            if develop.exposure != 0 {
                let f = CIFilter.exposureAdjust()
                f.inputImage = image
                f.ev = Float(develop.exposure)
                image = f.outputImage ?? image
            }
            if develop.temperature != 0 || develop.tint != 0 {
                let f = CIFilter.temperatureAndTint()
                f.inputImage = image
                f.neutral = CIVector(x: 6500 + CGFloat(develop.temperature * 2000), y: CGFloat(develop.tint * 50))
                f.targetNeutral = CIVector(x: 6500, y: 0)
                image = f.outputImage ?? image
            }
            return image
        }
    }

    private static func tone(_ input: CIImage, develop: DevelopParams, flatCurve: Bool) -> CIImage {
        var image = input
        if flatCurve {
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point0 = CGPoint(x: 0, y: 0.06)
            f.point1 = CGPoint(x: 0.2, y: 0.3)
            f.point2 = CGPoint(x: 0.5, y: 0.57)
            f.point3 = CGPoint(x: 0.8, y: 0.8)
            f.point4 = CGPoint(x: 1, y: 0.93)
            image = f.outputImage ?? image
        }
        if develop.highlights < 0 || develop.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 + min(0, develop.highlights))
            f.shadowAmount = Float(develop.shadows)
            image = f.outputImage ?? image
        }
        if develop.highlights > 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point0 = CGPoint(x: 0, y: 0)
            f.point1 = CGPoint(x: 0.25, y: 0.25)
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: 0.75 + 0.12 * develop.highlights)
            f.point4 = CGPoint(x: 1, y: 1)
            image = f.outputImage ?? image
        }
        if develop.contrast != 0 || develop.saturation != 0 || flatCurve {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + develop.contrast * 0.5)
            f.saturation = Float((1 + develop.saturation) * (flatCurve ? 0.8 : 1))
            f.brightness = 0
            image = f.outputImage ?? image
        }
        return image
    }

    private static func exifOrientation(of url: URL) -> CGImagePropertyOrientation {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let raw = props[kCGImagePropertyOrientation as String] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }
}
