import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

final class CropRanker {
    static let shared = CropRanker()

    static let shortSide = 256
    static let longSide = 352

    private let lock = NSLock()
    private var loaded = false
    private var model: MLModel?
    private var w1: [Float] = []
    private var b1: [Float] = []
    private var w2: [Float] = []
    private var b2: [Float] = []
    private var w3: [Float] = []
    private var b3: Float = 0

    private let channels = 8
    private let aligned = 9
    private let sampled = 10
    private let inputSize = 1296
    private let hidden1 = 768
    private let hidden2 = 128

    static func input(from image: CIImage, context: CIContext) -> CGImage? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let portrait = e.height >= e.width
        let w = CGFloat(portrait ? shortSide : longSide)
        let h = CGFloat(portrait ? longSide : shortSide)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: w / e.width, y: h / e.height))
        return context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func factors(_ scores: [Float]) -> [Double] {
        guard scores.count > 1 else { return scores.map { _ in 1 } }
        let values = scores.map { Double($0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let spread = max(variance.squareRoot(), 0.25)
        return values.map { 1 + 0.12 * min(max(($0 - mean) / spread, -2), 2) }
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return model != nil
    }

    func scores(for image: CGImage, rects: [CGRect]) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let model, !rects.isEmpty, let map = featureMap(model: model, image: image) else { return nil }
        let w = Float(image.width), h = Float(image.height)
        return rects.map { rect in
            let box = (Float(rect.minX) * w, Float(rect.minY) * h, Float(rect.maxX) * w, Float(rect.maxY) * h)
            return score(features(map, box: box))
        }
    }

    private struct FeatureMap {
        let values: [Float]
        let height: Int
        let width: Int
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let modelURL = Bundle.main.url(forResource: "GAICBackbone", withExtension: "mlmodelc"),
              let headURL = Bundle.main.url(forResource: "GAICHead", withExtension: "bin"),
              let data = try? Data(contentsOf: headURL) else { return }
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let expected = hidden1 * inputSize + hidden1 + hidden2 * hidden1 + hidden2 + hidden2 + 1
        guard floats.count == expected else { return }
        var offset = 0
        func take(_ count: Int) -> [Float] {
            defer { offset += count }
            return Array(floats[offset..<(offset + count)])
        }
        w1 = take(hidden1 * inputSize)
        b1 = take(hidden1)
        w2 = take(hidden2 * hidden1)
        b2 = take(hidden2)
        w3 = take(hidden2)
        b3 = take(1)[0]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: modelURL, configuration: configuration)
    }

    private func featureMap(model: MLModel, image: CGImage) -> FeatureMap? {
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let value = try? MLFeatureValue(cgImage: image, pixelsWide: image.width, pixelsHigh: image.height,
                                              pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [input.key: value]),
              let output = try? model.prediction(from: provider),
              let name = output.featureNames.first,
              let array = output.featureValue(for: name)?.multiArrayValue,
              array.shape.count == 4 else { return nil }
        let c = array.shape[1].intValue, h = array.shape[2].intValue, w = array.shape[3].intValue
        guard c == channels, h >= 2, w >= 2 else { return nil }
        var values = [Float](repeating: 0, count: c * h * w)
        for ci in 0..<c {
            for y in 0..<h {
                for x in 0..<w {
                    let key: [NSNumber] = [0, NSNumber(value: ci), NSNumber(value: y), NSNumber(value: x)]
                    values[(ci * h + y) * w + x] = array[key].floatValue
                }
            }
        }
        return FeatureMap(values: values, height: h, width: w)
    }

    private func features(_ map: FeatureMap, box: (Float, Float, Float, Float)) -> [Float] {
        let roi = pooled(sampleRoI(map, box: box))
        let rod = pooled(sampleRoD(map, box: box))
        return roi + rod
    }

    private func bilinear(_ map: FeatureMap, _ channel: Int, _ h: Float, _ w: Float) -> Float {
        let hstart = Int(min(floorf(h), Float(map.height - 2)))
        let wstart = Int(min(floorf(w), Float(map.width - 2)))
        let hr = h - Float(hstart)
        let wr = w - Float(wstart)
        let base = (channel * map.height + hstart) * map.width + wstart
        let v = map.values
        return v[base] * (1 - hr) * (1 - wr)
            + v[base + 1] * (1 - hr) * wr
            + v[base + map.width] * hr * (1 - wr)
            + v[base + map.width + 1] * hr * wr
    }

    private func sampleRoI(_ map: FeatureMap, box: (Float, Float, Float, Float)) -> [Float] {
        let scale: Float = 1.0 / 16
        let sw = box.0 * scale, sh = box.1 * scale, ew = box.2 * scale, eh = box.3 * scale
        let roiWidth = max(ew - sw + 1, 0)
        let roiHeight = max(eh - sh + 1, 0)
        let binH = roiHeight / Float(sampled - 1)
        let binW = roiWidth / Float(sampled - 1)
        let H = Float(map.height), W = Float(map.width)
        var out = [Float](repeating: 0, count: channels * sampled * sampled)
        for ph in 0..<sampled {
            for pw in 0..<sampled {
                let h = Float(ph) * binH + sh
                let w = Float(pw) * binW + sw
                if h < 0 || h >= H || w < 0 || w >= W { continue }
                for c in 0..<channels {
                    out[(c * sampled + ph) * sampled + pw] = bilinear(map, c, h, w)
                }
            }
        }
        return out
    }

    private func sampleRoD(_ map: FeatureMap, box: (Float, Float, Float, Float)) -> [Float] {
        let scale: Float = 1.0 / 16
        let sw = box.0 * scale, sh = box.1 * scale, ew = box.2 * scale, eh = box.3 * scale
        let binH = (Float(map.height) - 1.001) / Float(sampled - 1)
        let binW = (Float(map.width) - 1.001) / Float(sampled - 1)
        var out = [Float](repeating: 0, count: channels * sampled * sampled)
        for ph in 0..<sampled {
            for pw in 0..<sampled {
                let h = Float(ph) * binH
                let w = Float(pw) * binW
                if h >= sh && h <= eh && w >= sw && w <= ew { continue }
                for c in 0..<channels {
                    out[(c * sampled + ph) * sampled + pw] = bilinear(map, c, h, w)
                }
            }
        }
        return out
    }

    private func pooled(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: channels * aligned * aligned)
        for c in 0..<channels {
            for y in 0..<aligned {
                for xx in 0..<aligned {
                    let i = (c * sampled + y) * sampled + xx
                    out[(c * aligned + y) * aligned + xx] = 0.25 * (x[i] + x[i + 1] + x[i + sampled] + x[i + sampled + 1])
                }
            }
        }
        return out
    }

    private func score(_ x: [Float]) -> Float {
        var h1 = b1
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(hidden1), Int32(inputSize), 1, w1, Int32(inputSize), x, 1, 1, &h1, 1)
        for i in 0..<h1.count where h1[i] < 0 { h1[i] = 0 }
        var h2 = b2
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(hidden2), Int32(hidden1), 1, w2, Int32(hidden1), h1, 1, 1, &h2, 1)
        for i in 0..<h2.count where h2[i] < 0 { h2[i] = 0 }
        var result = b3
        for i in 0..<hidden2 { result += w3[i] * h2[i] }
        return result
    }
}
