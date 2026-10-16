import CoreGraphics

extension CGRect {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    var area: CGFloat { isNull ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other).area
        guard inter > 0 else { return 0 }
        return inter / (area + other.area - inter)
    }

    func coverage(of other: CGRect) -> CGFloat {
        let a = other.area
        guard a > 0 else { return 0 }
        return intersection(other).area / a
    }

    func lerp(to other: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * t,
               y: minY + (other.minY - minY) * t,
               width: width + (other.width - width) * t,
               height: height + (other.height - height) * t)
    }

    func zoomed(by factor: CGFloat) -> CGRect {
        CGRect(x: 0.5 + (minX - 0.5) * factor,
               y: 0.5 + (minY - 0.5) * factor,
               width: width * factor,
               height: height * factor)
    }

    func clampedInsideUnit() -> CGRect {
        var r = self
        r.size.width = min(r.width, 1)
        r.size.height = min(r.height, 1)
        r.origin.x = min(max(0, r.origin.x), 1 - r.width)
        r.origin.y = min(max(0, r.origin.y), 1 - r.height)
        return r
    }
}

enum UpDirection: Equatable {
    case top, right, bottom, left

    var isLandscape: Bool { self == .left || self == .right }

    func toUpright(_ p: CGPoint) -> CGPoint {
        switch self {
        case .top: return p
        case .right: return CGPoint(x: p.y, y: 1 - p.x)
        case .left: return CGPoint(x: 1 - p.y, y: p.x)
        case .bottom: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        }
    }

    func fromUpright(_ p: CGPoint) -> CGPoint {
        switch self {
        case .top: return p
        case .right: return CGPoint(x: 1 - p.y, y: p.x)
        case .left: return CGPoint(x: p.y, y: 1 - p.x)
        case .bottom: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        }
    }

    func toUpright(_ r: CGRect) -> CGRect {
        let a = toUpright(CGPoint(x: r.minX, y: r.minY))
        let b = toUpright(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum AspectMode: String, CaseIterable, Identifiable {
    case auto, fourFive, threeFour, twoThree, square, threeTwo, sixteenNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .fourFive: return "4:5"
        case .threeFour: return "3:4"
        case .twoThree: return "2:3"
        case .square: return "1:1"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        }
    }

    var ratios: [Double] {
        switch self {
        case .auto: return [4.0 / 5, 3.0 / 4, 2.0 / 3, 1, 3.0 / 2, 4.0 / 3, 16.0 / 9]
        case .fourFive: return [4.0 / 5]
        case .threeFour: return [3.0 / 4]
        case .twoThree: return [2.0 / 3]
        case .square: return [1]
        case .threeTwo: return [3.0 / 2]
        case .sixteenNine: return [16.0 / 9]
        }
    }

    static func label(for ratio: Double) -> String {
        let table: [(Double, String)] = [
            (4.0 / 5, "4:5"), (3.0 / 4, "3:4"), (2.0 / 3, "2:3"), (1, "1:1"),
            (3.0 / 2, "3:2"), (4.0 / 3, "4:3"), (16.0 / 9, "16:9"),
        ]
        return table.min { abs($0.0 - ratio) < abs($1.0 - ratio) }?.1 ?? ""
    }
}

enum PhotoRotation {
    case none, clockwise, counterClockwise, upsideDown

    init(up: UpDirection) {
        switch up {
        case .top: self = .none
        case .right: self = .counterClockwise
        case .left: self = .clockwise
        case .bottom: self = .upsideDown
        }
    }
}
