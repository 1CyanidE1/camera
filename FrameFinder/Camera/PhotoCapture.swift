import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct ProcessedShot {
    let viewer: Data
    let original: Data
    let source: Data
    let sourceKind: ShotSource.Kind
    let thumbnail: UIImage?
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let crop: CGRect?
    private let rotation: PhotoRotation
    private let saveOriginal: Bool
    private let saveToPhotos: Bool
    private let willCapture: () -> Void
    private let completion: (ProcessedShot?, Bool) -> Void
    private let finished: () -> Void
    private var processedData: Data?
    private var rawData: Data?

    init(crop: CGRect?, rotation: PhotoRotation, saveOriginal: Bool, saveToPhotos: Bool,
         willCapture: @escaping () -> Void,
         completion: @escaping (ProcessedShot?, Bool) -> Void,
         finished: @escaping () -> Void) {
        self.crop = crop
        self.rotation = rotation
        self.saveOriginal = saveOriginal
        self.saveToPhotos = saveToPhotos
        self.willCapture = willCapture
        self.completion = completion
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { self.willCapture() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finished()
        let processed = processedData
        let raw = rawData
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let raw {
                let previewData = processed ?? PhotoProcessor.developRAW(raw)
                guard let preview = previewData, let result = PhotoProcessor.process(data: preview, crop: crop, rotation: rotation) else {
                    deliver(nil, false)
                    return
                }
                let shot = ProcessedShot(viewer: result.shot.viewer, original: result.shot.original,
                                         source: raw, sourceKind: .proRAW, thumbnail: result.shot.thumbnail)
                deliver(shot, false)
                return
            }
            guard let data = processed, let result = PhotoProcessor.process(data: data, crop: crop, rotation: rotation) else {
                deliver(nil, false)
                return
            }
            guard saveToPhotos else {
                deliver(result.shot, false)
                return
            }
            var items = [result.full]
            if saveOriginal, crop != nil {
                items.append(PhotoProcessor.process(data: data, crop: nil, rotation: rotation)?.full ?? data)
            }
            PhotoLibrary.save(items) { ok in self.deliver(result.shot, ok) }
        }
    }

    private func deliver(_ shot: ProcessedShot?, _ ok: Bool) {
        DispatchQueue.main.async { self.completion(shot, ok) }
    }
}

enum PhotoProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func developRAW(_ data: Data) -> Data? {
        guard let filter = CIRAWFilter(imageData: data, identifierHint: nil),
              let image = filter.outputImage else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return encode(atOrigin(image), colorSpace: colorSpace, metadata: [:], quality: 0.9)
    }

    static func process(data: Data, crop: CGRect?, rotation: PhotoRotation) -> (full: Data, shot: ProcessedShot)? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let whole = atOrigin(oriented(source, rotation))

        let framed: CIImage
        let full: Data
        if let crop {
            let e = source.extent
            let r = crop.intersection(.unit)
            guard !r.isNull, r.width > 0.02, r.height > 0.02 else { return nil }
            let pixelRect = CGRect(x: e.minX + r.minX * e.width,
                                   y: e.minY + (1 - r.maxY) * e.height,
                                   width: r.width * e.width,
                                   height: r.height * e.height).integral.intersection(e)
            framed = atOrigin(oriented(source.cropped(to: pixelRect), rotation))
            guard let encoded = encode(framed, colorSpace: colorSpace, metadata: source.properties, quality: 0.92) else { return nil }
            full = encoded
        } else if rotation == .none {
            framed = whole
            full = data
        } else {
            framed = whole
            guard let encoded = encode(whole, colorSpace: colorSpace, metadata: source.properties, quality: 0.92) else { return nil }
            full = encoded
        }

        guard let viewer = encode(scaled(framed, maxSide: 3072), colorSpace: colorSpace, metadata: [:], quality: 0.85),
              let original = encode(scaled(whole, maxSide: 1280), colorSpace: colorSpace, metadata: [:], quality: 0.8) else { return nil }
        return (full, ProcessedShot(viewer: viewer, original: original, source: data, sourceKind: .heic, thumbnail: thumbnail(viewer)))
    }

    static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxSide: 240)
    }

    static func thumbnail(from source: CGImageSource, maxSide: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func oriented(_ image: CIImage, _ rotation: PhotoRotation) -> CIImage {
        switch rotation {
        case .none: return image
        case .clockwise: return image.oriented(.right)
        case .counterClockwise: return image.oriented(.left)
        case .upsideDown: return image.oriented(.down)
        }
    }

    static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func scaled(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxSide else { return image }
        let s = maxSide / longest
        let resized = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: s,
            kCIInputAspectRatioKey: 1.0,
        ])
        return atOrigin(resized.cropped(to: resized.extent.integral))
    }

    static func encode(_ image: CIImage, colorSpace: CGColorSpace, metadata: [String: Any], quality: Double) -> Data? {
        guard let cgImage = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace) else { return nil }

        var properties = metadata
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.heic.identifier as CFString, 1, nil)
                ?? CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

enum PhotoLibrary {
    static func save(_ items: [Data], completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for data in items {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }, completionHandler: { ok, _ in completion(ok) })
        }
    }
}
