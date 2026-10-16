import CoreGraphics
import Foundation

struct OverlayState: Equatable {
    struct Frame: Equatable {
        var id: Int
        var rect: CGRect
        var subject: CGPoint
        var label: String
        var aesthetic: Double?
        var locked: Bool
        var aligned: Bool
        var visible: CGFloat
        var reasons: [ShotReason]
        var anchor: CGPoint?
        var faces: [CGRect]
    }

    var frame: Frame?
    var zoom: CGFloat = 1
    var readout = CameraReadout()
    var histogram: [UInt8] = []
    var faceOK = true
}

final class CompositionEngine {
    var locked = false
    var aspectMode: AspectMode = .auto
    var up: UpDirection = .top
    var imageAspect: Double = 3.0 / 4.0
    var neuralEnabled = false

    private struct Suggestion {
        let id: Int
        var rect: CGRect
        var ratio: Double
        var subject: CGPoint
        var compare: Double
        var hiddenSince: Double?
        var captured = false
        var reasons: [ShotReason] = []
        var anchor: CGPoint?
        var faces: [CGRect] = []
    }

    private struct NeuralEntry {
        let key: Int
        var rect: CGRect
        var factor: Double?
        let time: Double
    }

    private struct AestheticEntry {
        let key: Int
        var rect: CGRect
        var score: Double?
        let time: Double
    }

    private let switchMargin = 1.12
    private let switchStreak = 3

    private var current: Suggestion?
    private var challenger: (rect: CGRect, streak: Int)?
    private var candidates: [Candidate] = []
    private var aesthetics: [AestheticEntry] = []
    private var neural: [NeuralEntry] = []
    private var displayRect: CGRect?
    private var displayId = -1
    private var nextId = 1
    private var nextKey = 1

    func applyZoom(_ factor: Double) {
        let f = CGFloat(factor)
        transformAll { $0.zoomed(by: f) }
        if factor > 1, var c = current, c.rect.iou(.unit) > 0.8 {
            c.captured = true
            current = c
        }
    }

    func applyShift(dx: Double, dy: Double) {
        transformAll { $0.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)) }
    }

    private func transformAll(_ t: (CGRect) -> CGRect) {
        if var c = current {
            c.rect = t(c.rect)
            c.subject = t(CGRect(origin: c.subject, size: .zero)).origin
            if let a = c.anchor { c.anchor = t(CGRect(origin: a, size: .zero)).origin }
            c.faces = c.faces.map(t)
            current = c
        }
        if var ch = challenger {
            ch.rect = t(ch.rect)
            challenger = ch
        }
        for i in aesthetics.indices { aesthetics[i].rect = t(aesthetics[i].rect) }
        for i in neural.indices { neural[i].rect = t(neural[i].rect) }
        for i in candidates.indices { candidates[i].rect = t(candidates[i].rect) }
        if let d = displayRect { displayRect = t(d) }
    }

    func ingest(_ scene: SceneAnalysis, now: Double) {
        guard let scorer = CompositionScorer(scene: scene, up: up) else {
            if var c = current, !locked {
                c.compare *= 0.97
                current = c
            }
            return
        }
        defer { explain(with: scorer) }
        let ratios = aspectMode.ratios
        candidates = scorer.search(ratios: ratios, imageAspect: imageAspect)
        guard let top = candidates.first else { return }

        var currentRaw: Double?
        if var c = current {
            if CGRect.unit.coverage(of: c.rect) > 0.92 {
                let sc = scorer.score(c.rect.clampedInsideUnit(), ratio: c.ratio)
                currentRaw = sc.value
                c.subject = sc.subject
                c.hiddenSince = nil
            } else if c.hiddenSince == nil {
                c.hiddenSince = now
            }
            current = c
        }

        let norm = max(top.raw, currentRaw ?? 0, 1e-9)
        func compare(_ rect: CGRect, _ raw: Double) -> Double {
            raw / norm * aestheticFactor(for: rect) * (neuralFactor(for: rect) ?? 1)
        }

        guard var cur = current else {
            adopt(top, compare: compare(top.rect, top.raw))
            return
        }
        if let raw = currentRaw {
            cur.compare = compare(cur.rect, raw)
        } else if !locked {
            cur.compare *= CGRect.unit.coverage(of: cur.rect) >= 0.3 ? 0.985 : 0.95
        }
        current = cur
        if locked {
            challenger = nil
            return
        }

        if !ratios.contains(where: { abs($0 - cur.ratio) < 0.001 }) {
            adopt(top, compare: compare(top.rect, top.raw))
            return
        }

        if let since = cur.hiddenSince, now - since > 3, CGRect.unit.coverage(of: cur.rect) < 0.5 {
            adopt(top, compare: compare(top.rect, top.raw))
            return
        }

        if let rival = candidates.first(where: { $0.rect.iou(cur.rect) < 0.5 }) {
            let guarded = cur.captured || cur.rect.coverage(of: rival.rect) > 0.9
            let rivalCompare = compare(rival.rect, rival.raw)
            if rivalCompare > cur.compare * (guarded ? 1.5 : switchMargin) {
                var streak = 1
                if let ch = challenger, ch.rect.iou(rival.rect) > 0.5 { streak = ch.streak + 1 }
                challenger = (rival.rect, streak)
                if streak >= switchStreak + (guarded ? 2 : 0) {
                    adopt(rival, compare: rivalCompare)
                    return
                }
            } else {
                challenger = nil
            }
        } else {
            challenger = nil
        }

        if let near = candidates.first(where: { $0.rect.iou(cur.rect) >= 0.5 && abs($0.ratio - cur.ratio) < 0.001 }),
           compare(near.rect, near.raw) > cur.compare * 1.05 {
            cur.rect = cur.rect.lerp(to: near.rect, 0.25)
            current = cur
        }
    }

    private func explain(with scorer: CompositionScorer) {
        guard var c = current, CGRect.unit.coverage(of: c.rect) > 0.92 else { return }
        let rect = c.rect.clampedInsideUnit()
        let b = scorer.breakdown(rect, ratio: c.ratio)
        let whole = scorer.breakdown(.unit, ratio: up.isLandscape ? 4.0 / 3.0 : 3.0 / 4.0).value
        c.reasons = Explainer.reasons(for: b, wholeValue: whole, aesthetic: aestheticScore(for: c.rect),
                                      neural: neuralFactor(for: c.rect))
        c.anchor = b.anchor
        c.faces = scorer.wholeFaces(in: rect)
        current = c
    }

    private func adopt(_ c: Candidate, compare: Double) {
        current = Suggestion(id: nextId, rect: c.rect, ratio: c.ratio, subject: c.subject, compare: compare, hiddenSince: nil)
        nextId += 1
        challenger = nil
    }

    func aestheticJobs(now: Double) -> [(key: Int, rect: CGRect)] {
        aesthetics.removeAll { now - $0.time > 4 }
        var targets: [CGRect] = []
        if let c = current { targets.append(c.rect) }
        if let ch = challenger { targets.append(ch.rect) }
        targets += candidates.map(\.rect)

        var jobs: [(key: Int, rect: CGRect)] = []
        for t in targets {
            if jobs.count >= 3 { break }
            guard CGRect.unit.coverage(of: t) > 0.97 else { continue }
            let r = t.clampedInsideUnit()
            if jobs.contains(where: { $0.rect.iou(r) > 0.75 }) { continue }
            if aesthetics.contains(where: { $0.rect.iou(r) > 0.85 && now - $0.time < 1.5 }) { continue }
            let key = nextKey
            nextKey += 1
            aesthetics.append(AestheticEntry(key: key, rect: r, score: nil, time: now))
            jobs.append((key: key, rect: r))
        }
        return jobs
    }

    func neuralJobs(now: Double) -> [(key: Int, rect: CGRect)] {
        guard neuralEnabled else { return [] }
        neural.removeAll { now - $0.time > 3 }
        var targets: [CGRect] = []
        if let c = current { targets.append(c.rect) }
        if let ch = challenger { targets.append(ch.rect) }
        targets += candidates.map(\.rect)
        var jobs: [(key: Int, rect: CGRect)] = []
        for t in targets {
            if jobs.count >= 10 { break }
            guard CGRect.unit.coverage(of: t) > 0.97 else { continue }
            let r = t.clampedInsideUnit()
            if jobs.contains(where: { $0.rect.iou(r) > 0.85 }) { continue }
            let key = nextKey
            nextKey += 1
            neural.append(NeuralEntry(key: key, rect: r, factor: nil, time: now))
            jobs.append((key: key, rect: r))
        }
        return jobs
    }

    func setNeural(_ results: [(key: Int, factor: Double)]) {
        for result in results {
            if let i = neural.firstIndex(where: { $0.key == result.key }) {
                neural[i].factor = result.factor
            }
        }
    }

    private func neuralFactor(for rect: CGRect) -> Double? {
        guard neuralEnabled else { return nil }
        return neural
            .filter { $0.factor != nil && $0.rect.iou(rect) > 0.75 }
            .max { $0.time < $1.time }?
            .factor
    }

    func setAesthetic(key: Int, score: Double) {
        if let i = aesthetics.firstIndex(where: { $0.key == key }) {
            aesthetics[i].score = score
        }
    }

    private func aestheticScore(for rect: CGRect) -> Double? {
        aesthetics
            .filter { $0.score != nil && $0.rect.iou(rect) > 0.75 }
            .max { $0.time < $1.time }?
            .score
    }

    private func aestheticFactor(for rect: CGRect) -> Double {
        guard let s = aestheticScore(for: rect) else { return 1 }
        return 0.8 + 0.4 * s
    }

    func overlayFrame() -> OverlayState.Frame? {
        guard let c = current else {
            displayRect = nil
            return nil
        }
        let shown: CGRect
        if let d = displayRect, displayId == c.id {
            shown = d.lerp(to: c.rect, 0.6)
        } else {
            shown = c.rect
        }
        displayRect = shown
        displayId = c.id

        return OverlayState.Frame(
            id: c.id,
            rect: shown,
            subject: c.subject,
            label: AspectMode.label(for: c.ratio),
            aesthetic: aestheticScore(for: c.rect),
            locked: locked,
            aligned: shown.iou(.unit) > 0.8,
            visible: CGRect.unit.coverage(of: shown),
            reasons: c.reasons,
            anchor: c.anchor,
            faces: c.faces
        )
    }
}
