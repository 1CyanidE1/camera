import CoreGraphics
import CoreVideo
import QuartzCore
import Vision

struct SceneAnalysis {
    var heat: [Double]
    var gw: Int
    var gh: Int
    var peak: Double
    var subjects: [CGRect]
    var faces: [CGRect]
    var bodies: [CGRect]
    var eyes: [CGPoint] = []
}

final class SceneAnalyzer {
    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        return request
    }()
    private var lastLandmarks: CFTimeInterval = 0
    private var cachedEyes: [CGPoint] = []

    func analyze(_ pixelBuffer: CVPixelBuffer) -> SceneAnalysis? {
        run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]), landmarksEvery: 0.3)
    }

    func analyze(_ image: CGImage) -> SceneAnalysis? {
        run(VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]), landmarksEvery: 0)
    }

    private func run(_ handler: VNImageRequestHandler, landmarksEvery interval: CFTimeInterval) -> SceneAnalysis? {
        do {
            try handler.perform([saliencyRequest, faceRequest, humanRequest])
        } catch {
            return nil
        }
        guard let saliency = saliencyRequest.results?.first else { return nil }

        let map = saliency.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        var heat = [Double](repeating: 0, count: w * h)
        var peak = 0.0
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                let v = Double(row[x])
                heat[y * w + x] = v
                if v > peak { peak = v }
            }
        }

        let faceObservations = faceRequest.results ?? []
        let now = CACurrentMediaTime()
        if faceObservations.isEmpty {
            cachedEyes = []
        } else if now - lastLandmarks >= interval {
            lastLandmarks = now
            landmarksRequest.inputFaceObservations = faceObservations
            if (try? handler.perform([landmarksRequest])) != nil {
                cachedEyes = (landmarksRequest.results ?? []).compactMap(Self.sharpestEye)
            }
        }

        return SceneAnalysis(
            heat: heat, gw: w, gh: h, peak: peak,
            subjects: (saliency.salientObjects ?? []).map { Self.topLeft($0.boundingBox) },
            faces: faceObservations.map { Self.topLeft($0.boundingBox) },
            bodies: (humanRequest.results ?? []).map { Self.topLeft($0.boundingBox) },
            eyes: cachedEyes
        )
    }

    private static func sharpestEye(_ face: VNFaceObservation) -> CGPoint? {
        guard let landmarks = face.landmarks else { return nil }
        let box = face.boundingBox
        let eyes = [landmarks.leftEye, landmarks.rightEye].compactMap { region -> (CGPoint, CGFloat)? in
            guard let region, region.pointCount > 0 else { return nil }
            let points = region.normalizedPoints
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            return (center, (maxX - minX) * (maxY - minY))
        }
        guard let best = eyes.max(by: { $0.1 < $1.1 }) else { return nil }
        return CGPoint(x: box.minX + best.0.x * box.width, y: 1 - (box.minY + best.0.y * box.height))
    }

    private static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}
