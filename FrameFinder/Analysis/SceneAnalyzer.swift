import CoreVideo
import Vision

struct SceneAnalysis {
    var heat: [Double]
    var gw: Int
    var gh: Int
    var peak: Double
    var subjects: [CGRect]
    var faces: [CGRect]
    var bodies: [CGRect]
}

final class SceneAnalyzer {
    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        return request
    }()

    func analyze(_ pixelBuffer: CVPixelBuffer) -> SceneAnalysis? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
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

        return SceneAnalysis(
            heat: heat, gw: w, gh: h, peak: peak,
            subjects: (saliency.salientObjects ?? []).map { Self.topLeft($0.boundingBox) },
            faces: (faceRequest.results ?? []).map { Self.topLeft($0.boundingBox) },
            bodies: (humanRequest.results ?? []).map { Self.topLeft($0.boundingBox) }
        )
    }

    private static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}
