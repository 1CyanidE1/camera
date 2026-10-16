import CoreGraphics
import Foundation

struct Candidate {
    var rect: CGRect
    var raw: Double
    var ratio: Double
    var subject: CGPoint
}

final class CompositionScorer {
    private let gw: Int
    private let gh: Int
    private let sat: [Double]
    private let satX: [Double]
    private let satY: [Double]
    private let total: Double
    private let subjects: [CGRect]
    private let faces: [CGRect]
    private let bodies: [CGRect]
    private let up: UpDirection

    private static let areas: [Double] = [0.2, 0.27, 0.36, 0.47, 0.6, 0.76, 1.0]

    init?(scene: SceneAnalysis, up: UpDirection) {
        let n = scene.gw * scene.gh
        guard n > 0, scene.heat.count == n, scene.peak > 0.02 else { return nil }

        let sorted = scene.heat.sorted()
        let floor = sorted[Int(Double(n - 1) * 0.45)]
        let span = max(scene.peak - floor, 1e-6)

        let gw = scene.gw, gh = scene.gh, stride = gw + 1
        var s = [Double](repeating: 0, count: stride * (gh + 1))
        var sx = s, sy = s
        var total = 0.0
        for j in 0..<gh {
            var row = 0.0, rowX = 0.0, rowY = 0.0
            let cy = (Double(j) + 0.5) / Double(gh)
            for i in 0..<gw {
                var v = (scene.heat[j * gw + i] - floor) / span
                v = v > 0 ? pow(v, 1.4) : 0
                let cx = (Double(i) + 0.5) / Double(gw)
                row += v
                rowX += v * cx
                rowY += v * cy
                let k = (j + 1) * stride + (i + 1)
                s[k] = s[k - stride] + row
                sx[k] = sx[k - stride] + rowX
                sy[k] = sy[k - stride] + rowY
            }
            total += row
        }
        guard total > 1e-3 else { return nil }

        self.gw = gw
        self.gh = gh
        self.sat = s
        self.satX = sx
        self.satY = sy
        self.total = total
        self.subjects = scene.subjects
        self.faces = scene.faces
        self.bodies = scene.bodies
        self.up = up
    }

    func search(ratios: [Double], imageAspect: Double) -> [Candidate] {
        var all: [Candidate] = []
        all.reserveCapacity(ratios.count * Self.areas.count * 121)

        for ratio in ratios {
            let uiRatio = up.isLandscape ? 1 / ratio : ratio
            var lastWidth = -1.0
            for a in Self.areas {
                var w = (a * uiRatio / imageAspect).squareRoot()
                var h = (a * imageAspect / uiRatio).squareRoot()
                let k = min(1, 1 / w, 1 / h)
                w *= k
                h *= k
                if abs(w - lastWidth) < 0.01 { continue }
                lastWidth = w

                let nx = 1 - w < 0.01 ? 0 : 10
                let ny = 1 - h < 0.01 ? 0 : 10
                for iy in 0...ny {
                    for ix in 0...nx {
                        let x = nx == 0 ? 0 : (1 - w) * Double(ix) / Double(nx)
                        let y = ny == 0 ? 0 : (1 - h) * Double(iy) / Double(ny)
                        let r = CGRect(x: x, y: y, width: w, height: h)
                        let sc = score(r, ratio: ratio)
                        if sc.value > 0 {
                            all.append(Candidate(rect: r, raw: sc.value, ratio: ratio, subject: sc.subject))
                        }
                    }
                }
            }
        }

        all.sort { $0.raw > $1.raw }
        var picked: [Candidate] = []
        for c in all where picked.allSatisfy({ $0.rect.iou(c.rect) < 0.55 }) {
            picked.append(c)
            if picked.count == 6 { break }
        }
        return picked.map(refine).sorted { $0.raw > $1.raw }
    }

    private func refine(_ c: Candidate) -> Candidate {
        var best = c
        for step in [0.025, 0.01] {
            let base = best.rect
            for ds in [0.95, 1.0, 1.05] {
                let w = Double(base.width) * ds, h = Double(base.height) * ds
                guard w <= 1, h <= 1, w * h > 0.03 else { continue }
                for dy in -2...2 {
                    for dx in -2...2 {
                        let cx = Double(base.midX) + Double(dx) * step
                        let cy = Double(base.midY) + Double(dy) * step
                        let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).clampedInsideUnit()
                        let sc = score(r, ratio: c.ratio)
                        if sc.value > best.raw {
                            best = Candidate(rect: r, raw: sc.value, ratio: c.ratio, subject: sc.subject)
                        }
                    }
                }
            }
        }
        return best
    }

    func score(_ r: CGRect, ratio: Double) -> (value: Double, subject: CGPoint) {
        let area = Double(r.width * r.height)
        guard area > 0.02 else { return (0, r.center) }
        let m = mass(r)
        guard m > total * 0.03 else { return (0, r.center) }
        let subject = CGPoint(x: sum(satX, r) / m, y: sum(satY, r) / m)

        let coverage = m / total
        let density = coverage / area
        var s = coverage * pow(density, 0.35)

        let ur = up.toUpright(r)
        let us = up.toUpright(subject)
        let u = Double((us.x - ur.minX) / ur.width)
        let v = Double((us.y - ur.minY) / ur.height)
        var d2 = Double.greatestFiniteMagnitude
        for px in [1.0 / 3, 2.0 / 3] {
            for py in [1.0 / 3, 2.0 / 3] {
                d2 = min(d2, (u - px) * (u - px) + (v - py) * (v - py))
            }
        }
        let thirds = exp(-d2 / (2 * 0.09 * 0.09))
        let du = u - 0.5, dv = v - 0.5
        let centred = exp(-(du * du + dv * dv) / (2 * 0.07 * 0.07))
        s *= 0.5 + 0.5 * max(thirds, 0.8 * centred)

        let band = 0.08 * min(r.width, r.height)
        let inner = r.insetBy(dx: band, dy: band)
        let bandArea = area - Double(inner.area)
        if bandArea > 1e-4 {
            let edgeDensity = (m - mass(inner)) / bandArea
            let relative = edgeDensity / (m / area)
            s *= exp(-max(0, relative - 0.5) * 1.5)
        }

        for box in subjects {
            let f = Double(r.coverage(of: box))
            if f > 0.03 && f < 0.97 { s *= 1 - 0.45 * sin(.pi * f) }
        }

        var mainFace: CGRect?
        for face in faces {
            let f = Double(r.coverage(of: face))
            if f > 0.03 && f < 0.98 {
                s *= 0.3
            } else if f >= 0.98, face.area > (mainFace?.area ?? 0) {
                mainFace = face
            }
        }
        if let face = mainFace {
            let uf = up.toUpright(face)
            let headroom = Double((uf.minY - ur.minY) / ur.height)
            let eyeLine = Double((uf.midY - ur.minY) / ur.height)
            if headroom < 0.04 { s *= 0.7 }
            s *= 0.75 + 0.25 * exp(-pow(eyeLine - 0.36, 2) / (2 * 0.12 * 0.12))
        } else {
            for body in bodies {
                let f = Double(r.coverage(of: body))
                if f > 0.2 && f < 0.92 { s *= 0.8 }
            }
        }

        if area < 0.3 { s *= pow(area / 0.3, 1.2) }

        s *= Self.ratioPrior(ratio)
        return (s, subject)
    }

    private static func ratioPrior(_ r: Double) -> Double {
        switch r {
        case ..<0.7: return 0.97
        case ..<0.9: return 1.0
        case ..<1.1: return 0.97
        case ..<1.6: return 0.96
        default: return 0.94
        }
    }

    private func mass(_ r: CGRect) -> Double { max(0, sum(sat, r)) }

    private func sum(_ table: [Double], _ r: CGRect) -> Double {
        let x0 = Double(r.minX), x1 = Double(r.maxX), y0 = Double(r.minY), y1 = Double(r.maxY)
        return lookup(table, x1, y1) - lookup(table, x0, y1) - lookup(table, x1, y0) + lookup(table, x0, y0)
    }

    private func lookup(_ table: [Double], _ u: Double, _ v: Double) -> Double {
        let x = min(max(u, 0), 1) * Double(gw)
        let y = min(max(v, 0), 1) * Double(gh)
        let i = min(Int(x), gw - 1), j = min(Int(y), gh - 1)
        let fx = x - Double(i), fy = y - Double(j)
        let stride = gw + 1
        let k = j * stride + i
        let a00 = table[k], a10 = table[k + 1]
        let a01 = table[k + stride], a11 = table[k + stride + 1]
        return (a00 * (1 - fx) + a10 * fx) * (1 - fy) + (a01 * (1 - fx) + a11 * fx) * fy
    }
}
