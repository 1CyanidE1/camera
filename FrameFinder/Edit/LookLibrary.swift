import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct Look: Identifiable, Equatable {
    enum Kind {
        case none, auto, neural, cube, cloud
    }

    let id: String
    let title: String
    let kind: Kind
}

enum LookLibrary {
    static let all: [Look] = [
        Look(id: "none", title: "Нет", kind: .none),
        Look(id: "auto", title: "Авто", kind: .auto),
        Look(id: "neural", title: "Нейро", kind: .neural),
        Look(id: "warmFilm", title: "Тёплая плёнка", kind: .cube),
        Look(id: "tealOrange", title: "Кино", kind: .cube),
        Look(id: "softPastel", title: "Пастель", kind: .cube),
        Look(id: "nordic", title: "Холодный", kind: .cube),
        Look(id: "vivid", title: "Сочный", kind: .cube),
        Look(id: "mono", title: "Ч/Б", kind: .cube),
        Look(id: "cloud", title: "Облачный колорист", kind: .cloud),
    ]

    static let size = 33
    private static var cubes: [String: Data] = [:]
    private static let lock = NSLock()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func apply(_ params: ColorParams, to image: CIImage) -> CIImage {
        let graded: CIImage
        switch params.look {
        case "none", "cloud":
            return image
        case "auto":
            graded = autoAdjusted(image)
        case "neural":
            guard let data = NeuralColor.shared.cube(for: image) else { return image }
            graded = applyCube(data, size: NeuralColor.cubeSize, to: image)
        default:
            guard let data = cube(params.look) else { return image }
            graded = applyCube(data, size: size, to: image)
        }
        let intensity = min(max(params.intensity, 0), 1)
        guard intensity < 0.999 else { return graded }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = image
        blend.targetImage = graded
        blend.time = Float(intensity)
        return blend.outputImage?.cropped(to: image.extent) ?? graded
    }

    static func applyCube(_ data: Data, size: Int, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = data
        filter.colorSpace = sRGB
        return filter.outputImage ?? image
    }

    private static func autoAdjusted(_ image: CIImage) -> CIImage {
        let probe = PhotoProcessor.scaled(image, maxSide: 1024)
        let filters = probe.autoAdjustmentFilters(options: [.redEye: false])
        var current = image
        for filter in filters {
            filter.setValue(current, forKey: kCIInputImageKey)
            current = filter.outputImage ?? current
        }
        return current
    }

    static func cube(_ id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cubes[id] { return cached }
        guard let maker = transform(for: id) else { return nil }
        let data = makeCube(size: size, maker)
        cubes[id] = data
        return data
    }

    static func makeCube(size n: Int, _ transform: (Double, Double, Double) -> (Double, Double, Double)) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = transform(Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    values[i] = Float(clamp01(out.0))
                    values[i + 1] = Float(clamp01(out.1))
                    values[i + 2] = Float(clamp01(out.2))
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func transform(for id: String) -> ((Double, Double, Double) -> (Double, Double, Double))? {
        switch id {
        case "warmFilm":
            return { r, g, b in
                var c = (sCurve(r, 0.35), sCurve(g, 0.3), sCurve(b, 0.25))
                c = saturated(c, 0.88)
                let l = lumaOf(c)
                let hi = smoothStep(0.45, 1, l)
                return (liftBlack(c.0, 0.045) + 0.035 * hi, liftBlack(c.1, 0.04) + 0.012 * hi, liftBlack(c.2, 0.05) - 0.04 * hi)
            }
        case "tealOrange":
            return { r, g, b in
                var c = (sCurve(r, 0.3), sCurve(g, 0.3), sCurve(b, 0.3))
                let l = lumaOf(c)
                let shadow = 1 - smoothStep(0, 0.55, l)
                let hi = smoothStep(0.4, 1, l)
                c = (c.0 + 0.07 * hi - 0.05 * shadow, c.1 + 0.015 * hi + 0.02 * shadow, c.2 - 0.06 * hi + 0.07 * shadow)
                return saturated(c, 1.05)
            }
        case "softPastel":
            return { r, g, b in
                var c = (sCurve(r, -0.25), sCurve(g, -0.25), sCurve(b, -0.25))
                c = saturated(c, 0.72)
                return (liftBlack(c.0, 0.08) + 0.02, liftBlack(c.1, 0.08), liftBlack(c.2, 0.08) + 0.015)
            }
        case "nordic":
            return { r, g, b in
                var c = (sCurve(r, 0.2), sCurve(g, 0.2), sCurve(b, 0.2))
                c = saturated(c, 0.68)
                return (liftBlack(c.0, 0.02) - 0.02, liftBlack(c.1, 0.02) + 0.005, liftBlack(c.2, 0.025) + 0.045)
            }
        case "vivid":
            return { r, g, b in
                let c = (sCurve(r, 0.25), sCurve(g, 0.25), sCurve(b, 0.25))
                let spread = max(c.0, c.1, c.2) - min(c.0, c.1, c.2)
                return saturated(c, 1 + 0.45 * (1 - spread))
            }
        case "mono":
            return { r, g, b in
                let y = sCurve(liftBlack(0.3 * r + 0.59 * g + 0.11 * b, 0.02), 0.5)
                return (y, y, y)
            }
        default:
            return nil
        }
    }
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
private func lumaOf(_ c: (Double, Double, Double)) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
private func liftBlack(_ x: Double, _ black: Double) -> Double { black + x * (1 - black) }

private func sCurve(_ x: Double, _ amount: Double) -> Double {
    clamp01(x - amount * sin(2 * Double.pi * x) / (2 * Double.pi))
}

private func smoothStep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

private func saturated(_ c: (Double, Double, Double), _ s: Double) -> (Double, Double, Double) {
    let l = lumaOf(c)
    return (l + (c.0 - l) * s, l + (c.1 - l) * s, l + (c.2 - l) * s)
}
