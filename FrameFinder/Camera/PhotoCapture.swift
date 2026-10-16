import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let crop: CGRect?
    private let rotation: PhotoRotation
    private let saveOriginal: Bool
    private let willCapture: () -> Void
    private let completion: (UIImage?, Bool) -> Void
    private let finished: () -> Void

    init(crop: CGRect?, rotation: PhotoRotation, saveOriginal: Bool,
         willCapture: @escaping () -> Void,
         completion: @escaping (UIImage?, Bool) -> Void,
         finished: @escaping () -> Void) {
        self.crop = crop
        self.rotation = rotation
        self.saveOriginal = saveOriginal
        self.willCapture = willCapture
        self.completion = completion
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { self.willCapture() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            deliver(nil, false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let rendered: Data?
            if crop == nil && rotation == .none {
                rendered = data
            } else {
                rendered = PhotoProcessor.render(data: data, crop: crop ?? .unit, rotation: rotation)
            }
            guard let main = rendered else {
                deliver(nil, false)
                return
            }
            var items = [main]
            if saveOriginal, crop != nil {
                let original = rotation == .none ? data : PhotoProcessor.render(data: data, crop: .unit, rotation: rotation)
                items.append(original ?? data)
            }
            let thumbnail = PhotoProcessor.thumbnail(main)
            PhotoLibrary.save(items) { ok in self.deliver(thumbnail, ok) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finished()
    }

    private func deliver(_ image: UIImage?, _ ok: Bool) {
        DispatchQueue.main.async { self.completion(image, ok) }
    }
}

enum PhotoProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(data: Data, crop: CGRect, rotation: PhotoRotation) -> Data? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let e = source.extent
        let r = crop.intersection(.unit)
        guard !r.isNull, r.width > 0.02, r.height > 0.02 else { return nil }

        let pixelRect = CGRect(x: e.minX + r.minX * e.width,
                               y: e.minY + (1 - r.maxY) * e.height,
                               width: r.width * e.width,
                               height: r.height * e.height).integral.intersection(e)
        var image = source.cropped(to: pixelRect)
        switch rotation {
        case .none: break
        case .clockwise: image = image.oriented(.right)
        case .counterClockwise: image = image.oriented(.left)
        case .upsideDown: image = image.oriented(.down)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else { return nil }

        var properties = source.properties
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
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.heic.identifier as CFString, 1, nil)
                ?? CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
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
