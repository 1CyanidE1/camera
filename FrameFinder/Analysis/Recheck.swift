import CoreImage
import Foundation
import Vision

struct RecheckResult: Equatable {
    let crop: CGRect
    let ratio: Double
    let label: String
    let reasons: [ShotReason]
    let aesthetic: Double?
    let gain: Double
}

enum Recheck {
    static func run(record: ShotRecord, store: ShotStore) async -> RecheckResult? {
        guard let source = RenderSource(record: record, store: store), record.source?.precropped != true,
              let image = RenderPipeline.render(source, develop: record.develop ?? DevelopParams(), color: nil,
                                                crop: false, maxSide: 1920, draft: true),
              let cg = PhotoProcessor.context.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let scene = SceneAnalyzer().analyze(cg),
              let scorer = CompositionScorer(scene: scene, up: .top) else { return nil }

        let aspect = Double(cg.width) / Double(cg.height)
        let candidates = scorer.search(ratios: AspectMode.auto.ratios, imageAspect: aspect)
        guard let best = candidates.first else { return nil }

        let current = record.crop ?? .unit
        let currentRatio = Double(current.width) * aspect / max(Double(current.height), 0.001)
        let currentRaw = scorer.score(current, ratio: currentRatio).value

        let bestAesthetic = await aesthetic(of: best.rect, in: cg)
        let currentAesthetic = await aesthetic(of: current, in: cg)
        func combined(_ raw: Double, _ a: Double?) -> Double { raw * (0.8 + 0.4 * (a ?? 0.5)) }
        var bestFactor = 1.0, currentFactor = 1.0
        let ranked = Array(candidates.prefix(6).map(\.rect)) + [current]
        if CropRanker.shared.isAvailable,
           let input = CropRanker.input(from: CIImage(cgImage: cg), context: PhotoProcessor.context),
           let scores = CropRanker.shared.scores(for: input, rects: ranked), scores.count == ranked.count {
            let factors = CropRanker.factors(scores)
            bestFactor = factors[0]
            currentFactor = factors[factors.count - 1]
        }
        let newScore = combined(best.raw, bestAesthetic) * bestFactor
        let oldScore = max(combined(currentRaw, currentAesthetic) * currentFactor, 1e-9)
        let gain = newScore / oldScore

        guard gain >= 1.1, best.rect.iou(current) < 0.8 else { return nil }
        let breakdown = scorer.breakdown(best.rect, ratio: best.ratio)
        let whole = scorer.breakdown(.unit, ratio: aspect).value
        let reasons = Explainer.reasons(for: breakdown, wholeValue: whole, aesthetic: bestAesthetic,
                                        neural: bestFactor == 1 ? nil : bestFactor)
        return RecheckResult(crop: best.rect, ratio: best.ratio, label: AspectMode.label(for: best.ratio),
                             reasons: reasons, aesthetic: bestAesthetic, gain: gain)
    }

    private static func aesthetic(of rect: CGRect, in image: CGImage) async -> Double? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixels = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
        guard let crop = image.cropping(to: pixels),
              let observation = try? await CalculateImageAestheticsScoresRequest().perform(on: crop) else { return nil }
        return (Double(observation.overallScore) + 1) / 2
    }
}
