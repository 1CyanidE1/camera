import CoreImage
import CoreML
import Foundation

final class NeuralColor {
    static let shared = NeuralColor()
    static let cubeSize = 33

    private let lock = NSLock()
    private var loaded = false
    private var model: MLModel?
    private var basis: [Float] = []
    private let context = CIContext(options: [.cacheIntermediates: false])

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return model != nil && !basis.isEmpty
    }

    func cube(for image: CIImage) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard let model, !basis.isEmpty,
              let weights = predictWeights(model: model, image: image) else { return nil }
        return combine(weights)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let modelURL = Bundle.main.url(forResource: "NeuralLUT", withExtension: "mlmodelc"),
              let basisURL = Bundle.main.url(forResource: "LUTBasis", withExtension: "bin"),
              let data = try? Data(contentsOf: basisURL) else { return }
        let n = Self.cubeSize * Self.cubeSize * Self.cubeSize
        guard data.count == 3 * 3 * n * MemoryLayout<Float>.size else { return }
        basis = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: modelURL, configuration: configuration)
    }

    private func predictWeights(model: MLModel, image: CIImage) -> [Float]? {
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint else { return nil }
        let side = CGFloat(constraint.pixelsWide)
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let square = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: side / e.width, y: CGFloat(constraint.pixelsHigh) / e.height))
        let rect = CGRect(x: 0, y: 0, width: side, height: CGFloat(constraint.pixelsHigh))
        guard let cg = context.createCGImage(square, from: rect, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let value = try? MLFeatureValue(cgImage: cg, constraint: constraint, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [input.key: value]),
              let output = try? model.prediction(from: provider),
              let name = output.featureNames.first,
              let array = output.featureValue(for: name)?.multiArrayValue,
              array.count >= 3 else { return nil }
        return (0..<3).map { array[$0].floatValue }
    }

    private func combine(_ weights: [Float]) -> Data {
        let n = Self.cubeSize * Self.cubeSize * Self.cubeSize
        var values = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            for channel in 0..<3 {
                var v: Float = 0
                for lut in 0..<3 {
                    v += weights[lut] * basis[(lut * 3 + channel) * n + i]
                }
                values[i * 4 + channel] = min(max(v, 0), 1)
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
