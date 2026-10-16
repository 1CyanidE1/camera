import CoreVideo
import Foundation

final class MotionTracker {
    private var keyCols: [Float] = []
    private var keyRows: [Float] = []
    private var offX: Float = 0
    private var offY: Float = 0
    private var framesSinceKey = 0

    private let radius = 24

    func reset() {
        keyCols = []
        keyRows = []
    }

    func update(_ pixelBuffer: CVPixelBuffer) -> (dx: Double, dy: Double) {
        guard let profiles = Self.profiles(pixelBuffer) else {
            reset()
            return (0, 0)
        }
        let cols = profiles.cols, rows = profiles.rows
        guard cols.count == keyCols.count, rows.count == keyRows.count else {
            rekey(cols, rows)
            return (0, 0)
        }
        guard let nx = Self.match(cols, keyCols, around: offX, radius: radius),
              let ny = Self.match(rows, keyRows, around: offY, radius: radius) else {
            rekey(cols, rows)
            return (0, 0)
        }
        let dx = nx - offX, dy = ny - offY
        offX = nx
        offY = ny
        framesSinceKey += 1
        if abs(offX) > 12 || abs(offY) > 12 || framesSinceKey > 150 {
            rekey(cols, rows)
        }
        return (Double(dx) / Double(cols.count), Double(dy) / Double(rows.count))
    }

    private func rekey(_ cols: [Float], _ rows: [Float]) {
        keyCols = cols
        keyRows = rows
        offX = 0
        offY = 0
        framesSinceKey = 0
    }

    private static func profiles(_ pb: CVPixelBuffer) -> (cols: [Float], rows: [Float])? {
        guard CVPixelBufferIsPlanar(pb) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }

        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let step = max(1, min(w, h) / 160)
        let nc = w / step, nr = h / step
        guard nc > 32, nr > 32 else { return nil }

        var cols = [Float](repeating: 0, count: nc)
        var rows = [Float](repeating: 0, count: nr)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        cols.withUnsafeMutableBufferPointer { cb in
            rows.withUnsafeMutableBufferPointer { rb in
                for r in 0..<nr {
                    let line = luma + r * step * bytesPerRow
                    var acc: Float = 0
                    for c in 0..<nc {
                        let v = Float(line[c * step])
                        cb[c] += v
                        acc += v
                    }
                    rb[r] = acc
                }
            }
        }
        guard let nCols = normalize(smooth(cols)), let nRows = normalize(smooth(rows)) else { return nil }
        return (nCols, nRows)
    }

    private static func smooth(_ a: [Float]) -> [Float] {
        guard a.count > 2 else { return a }
        var out = a
        for i in 1..<(a.count - 1) {
            out[i] = (a[i - 1] + 2 * a[i] + a[i + 1]) * 0.25
        }
        return out
    }

    private static func normalize(_ a: [Float]) -> [Float]? {
        let n = Float(a.count)
        let mean = a.reduce(0, +) / n
        var variance: Float = 0
        for v in a { variance += (v - mean) * (v - mean) }
        let sd = (variance / n).squareRoot()
        guard sd > mean * 0.004 + 1e-3 else { return nil }
        return a.map { ($0 - mean) / sd }
    }

    private static func match(_ cur: [Float], _ ref: [Float], around center: Float, radius: Int) -> Float? {
        let n = cur.count
        let c0 = Int(center.rounded())
        let minOverlap = n * 6 / 10
        var costs = [Float](repeating: .infinity, count: 2 * radius + 1)
        var best = Float.infinity
        var bestK = -1

        cur.withUnsafeBufferPointer { cp in
            ref.withUnsafeBufferPointer { rp in
                for k in 0...(2 * radius) {
                    let d = c0 - radius + k
                    let lo = max(0, d), hi = min(n, n + d)
                    if hi - lo < minOverlap { continue }
                    let count = Float(hi - lo)
                    var meanCur: Float = 0, meanRef: Float = 0
                    for i in lo..<hi {
                        meanCur += cp[i]
                        meanRef += rp[i - d]
                    }
                    meanCur /= count
                    meanRef /= count
                    var sum: Float = 0
                    for i in lo..<hi { sum += abs((cp[i] - meanCur) - (rp[i - d] - meanRef)) }
                    let cost = sum / count
                    costs[k] = cost
                    if cost < best {
                        best = cost
                        bestK = k
                    }
                }
            }
        }
        guard bestK >= 0, best < 0.55 else { return nil }

        var sub: Float = 0
        if bestK > 0, bestK < 2 * radius, costs[bestK - 1].isFinite, costs[bestK + 1].isFinite {
            let a = costs[bestK - 1], b = costs[bestK], c = costs[bestK + 1]
            let denom = a - 2 * b + c
            if denom > 1e-6 { sub = max(-0.5, min(0.5, 0.5 * (a - c) / denom)) }
        }
        return Float(c0 - radius + bestK) + sub
    }
}
