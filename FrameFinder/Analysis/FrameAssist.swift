import CoreGraphics
import CoreVideo
import Foundation

struct AssistOptions: Equatable {
    var zebra = false
    var peaking = false
    var histogram = true
}

final class FrameAssist {
    static let histogramBins = 64

    static func histogram(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferIsPlanar(pixelBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        var counts = [Int](repeating: 0, count: histogramBins)
        let step = 6
        var y = 0
        while y < h {
            let row = luma + y * bytesPerRow
            var x = 0
            while x < w {
                counts[Int(row[x]) >> 2] += 1
                x += step
            }
            y += step
        }
        let peak = Double(counts.max() ?? 1)
        guard peak > 0 else { return nil }
        return counts.map { UInt8(min(255, (Double($0) / peak).squareRoot() * 255)) }
    }

    static func mask(_ pixelBuffer: CVPixelBuffer, zebra: Bool, peaking: Bool) -> CGImage? {
        guard CVPixelBufferIsPlanar(pixelBuffer), zebra || peaking else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let s = 2
        let mw = w / s, mh = h / s
        guard mw > 8, mh > 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: mw * mh * 4)

        var threshold = Int.max
        var magnitudes = [UInt16]()
        if peaking {
            magnitudes = [UInt16](repeating: 0, count: mw * mh)
            var counts = [Int](repeating: 0, count: 512)
            for my in 2..<(mh - 2) {
                let y = my * s
                let row = luma + y * bytesPerRow
                let up = luma + (y - s) * bytesPerRow
                let down = luma + (y + s) * bytesPerRow
                for mx in 2..<(mw - 2) {
                    let x = mx * s
                    let gx = abs(Int(row[x + s]) - Int(row[x - s]))
                    let gy = abs(Int(down[x]) - Int(up[x]))
                    let g = min(gx + gy, 511)
                    magnitudes[my * mw + mx] = UInt16(g)
                    counts[g] += 1
                }
            }
            let total = (mw - 4) * (mh - 4)
            var above = 0
            var t = 511
            while t > 0 {
                above += counts[t]
                if above > total / 25 { break }
                t -= 1
            }
            threshold = max(t, 48)
        }

        pixels.withUnsafeMutableBufferPointer { out in
            for my in 0..<mh {
                let row = luma + (my * s) * bytesPerRow
                for mx in 0..<mw {
                    let o = (my * mw + mx) * 4
                    if peaking, Int(magnitudes[my * mw + mx]) >= threshold {
                        out[o] = 255
                        out[o + 1] = 40
                        out[o + 2] = 40
                        out[o + 3] = 255
                    } else if zebra, row[mx * s] >= 242, ((mx + my) / 5) % 2 == 0 {
                        out[o] = 150
                        out[o + 1] = 150
                        out[o + 2] = 150
                        out[o + 3] = 150
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: mw, height: mh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mw * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
