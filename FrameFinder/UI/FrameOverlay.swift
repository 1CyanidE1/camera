import SwiftUI

struct FrameOverlay: View {
    @ObservedObject var live: LiveState
    let explain: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let frame = live.overlay.frame {
                    FrameDrawing(frame: frame, size: geo.size, explain: explain)
                        .id(frame.id)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                }
                if live.level.visible {
                    LevelIndicator(level: live.level)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: live.overlay.frame?.id)
        }
        .allowsHitTesting(false)
    }
}

private struct FrameDrawing: View {
    let frame: OverlayState.Frame
    let size: CGSize
    let explain: Bool

    private func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func box(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private var rect: CGRect {
        CGRect(x: frame.rect.minX * size.width, y: frame.rect.minY * size.height,
               width: frame.rect.width * size.width, height: frame.rect.height * size.height)
    }

    private var tint: Color {
        if frame.aligned { return .green }
        return frame.locked ? .yellow : .white
    }

    var body: some View {
        let r = rect
        let color = tint
        let aligned = frame.aligned
        let offscreen = frame.visible < 0.5
        let showMarks = explain && !offscreen
        let subject = point(frame.subject)
        let anchor = frame.anchor.map(point)
        let faces = frame.faces.map(box)

        ZStack(alignment: .topLeading) {
            Canvas { ctx, canvas in
                let full = CGRect(origin: .zero, size: canvas)

                var dim = Path(full)
                dim.addRect(r)
                ctx.fill(dim, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))

                var grid = Path()
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3
                    let y = r.minY + r.height * CGFloat(i) / 3
                    grid.move(to: CGPoint(x: x, y: r.minY))
                    grid.addLine(to: CGPoint(x: x, y: r.maxY))
                    grid.move(to: CGPoint(x: r.minX, y: y))
                    grid.addLine(to: CGPoint(x: r.maxX, y: y))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
                ctx.stroke(Path(r), with: .color(color.opacity(0.55)), lineWidth: 1)

                let l = min(max(min(r.width, r.height) * 0.18, 14), 36)
                var corners = Path()
                corners.move(to: CGPoint(x: r.minX, y: r.minY + l))
                corners.addLine(to: CGPoint(x: r.minX, y: r.minY))
                corners.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
                corners.move(to: CGPoint(x: r.maxX - l, y: r.minY))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
                corners.move(to: CGPoint(x: r.maxX, y: r.maxY - l))
                corners.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                corners.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
                corners.move(to: CGPoint(x: r.minX + l, y: r.maxY))
                corners.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                corners.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
                var shadowed = ctx
                shadowed.addFilter(.shadow(color: .black.opacity(0.5), radius: 3))
                shadowed.stroke(corners, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                if showMarks {
                    for face in faces {
                        ctx.stroke(Path(roundedRect: face, cornerRadius: 6), with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
                    }
                    if let anchor {
                        var link = Path()
                        link.move(to: subject)
                        link.addLine(to: anchor)
                        ctx.stroke(link, with: .color(.yellow.opacity(0.8)), lineWidth: 1)
                        ctx.stroke(Path(ellipseIn: CGRect(x: anchor.x - 13, y: anchor.y - 13, width: 26, height: 26)),
                                   with: .color(.yellow), lineWidth: 2)
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: subject.x - 4, y: subject.y - 4, width: 8, height: 8)), with: .color(.yellow))
                }

                let c = CGPoint(x: full.midX, y: full.midY)
                let t = CGPoint(x: r.midX, y: r.midY)
                if !aligned && !offscreen && !showMarks && hypot(t.x - c.x, t.y - c.y) > min(full.width, full.height) * 0.06 {
                    var line = Path()
                    line.move(to: c)
                    line.addLine(to: t)
                    ctx.stroke(line, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 5]))
                    ctx.fill(Path(ellipseIn: CGRect(x: t.x - 5, y: t.y - 5, width: 10, height: 10)), with: .color(color))
                    var cross = Path()
                    cross.move(to: CGPoint(x: c.x - 9, y: c.y))
                    cross.addLine(to: CGPoint(x: c.x + 9, y: c.y))
                    cross.move(to: CGPoint(x: c.x, y: c.y - 9))
                    cross.addLine(to: CGPoint(x: c.x, y: c.y + 9))
                    ctx.stroke(cross, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                }

                if offscreen {
                    let dx = t.x - c.x, dy = t.y - c.y
                    let len = max(hypot(dx, dy), 1)
                    let ux = dx / len, uy = dy / len
                    let reach = min((full.width / 2 - 30) / max(abs(ux), 0.001),
                                    (full.height / 2 - 30) / max(abs(uy), 0.001))
                    let tip = CGPoint(x: c.x + ux * reach, y: c.y + uy * reach)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: tip.x + ux * 14, y: tip.y + uy * 14))
                    arrow.addLine(to: CGPoint(x: tip.x - uy * 11, y: tip.y + ux * 11))
                    arrow.addLine(to: CGPoint(x: tip.x + uy * 11, y: tip.y - ux * 11))
                    arrow.closeSubpath()
                    ctx.fill(arrow, with: .color(color))
                }
            }

            badge
                .offset(x: min(max(r.minX + 6, 6), size.width - 120),
                        y: min(max(r.minY + 6, 6), size.height - 30))
        }
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Text(frame.label)
            if let a = frame.aesthetic {
                Text("★ " + String(format: "%.1f", a * 10))
            }
            if frame.locked {
                Image(systemName: "lock.fill")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

struct LevelIndicator: View {
    let level: LevelState

    var body: some View {
        let isLevel = abs(level.tilt) < 0.0175
        ZStack {
            HStack(spacing: 84) {
                Capsule().frame(width: 16, height: 2)
                Capsule().frame(width: 16, height: 2)
            }
            .rotationEffect(.radians(level.angle - level.tilt))
            Capsule()
                .frame(width: isLevel ? 116 : 70, height: 2)
                .rotationEffect(.radians(level.angle))
        }
        .foregroundStyle(isLevel ? Color.yellow : Color.white.opacity(0.7))
        .shadow(color: .black.opacity(0.4), radius: 2)
        .animation(.easeOut(duration: 0.15), value: isLevel)
    }
}

struct ReasonList: View {
    let reasons: [ShotReason]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reasons, id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: reason.symbol)
                        .foregroundStyle(reason.good ? Color.green : Color.orange)
                        .frame(width: 20)
                    Text(reason.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.footnote)
    }
}

struct ExplainPanel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Почему этот кадр")
                    .font(.footnote.weight(.semibold))
                if let frame = live.overlay.frame, !frame.reasons.isEmpty {
                    ReasonList(reasons: Array(frame.reasons.prefix(5)))
                } else {
                    Text("Ищу кадр — объясню, как только найду")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .padding(10)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: live.overlay.frame?.reasons)
    }
}
