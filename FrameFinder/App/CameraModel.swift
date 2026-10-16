import AVFoundation
import CoreMotion
import SwiftUI
import UIKit

struct LevelState: Equatable {
    var visible = false
    var angle: Double = 0
    var tilt: Double = 0
}

final class LiveState: ObservableObject {
    @Published var overlay = OverlayState()
    @Published var level = LevelState()
}

final class CameraModel: ObservableObject {
    enum Phase { case starting, running, denied, failed }

    @Published var phase: Phase = .starting
    @Published var info: CameraInfo?
    @Published var aspect: AspectMode = .auto {
        didSet { pipeline.setAspect(aspect) }
    }
    @Published var saveOriginal = false
    @Published var thumbnail: UIImage?
    @Published var toast: String?
    @Published var flash = false
    @Published var busy = false
    @Published var focusMarker: CGPoint?

    let live = LiveState()
    let pipeline = CameraPipeline()

    private let motion = CMMotionManager()
    private var up: UpDirection = .top
    private var started = false
    private var pinchBase: CGFloat?
    private var lastFrameId: Int?
    private var wasAligned = false

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let shutterHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let successHaptic = UINotificationFeedbackGenerator()

    func start() {
        guard !started else { return }
        started = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            launch()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.launch() } else { self.phase = .denied }
                }
            }
        default:
            phase = .denied
        }
    }

    private func launch() {
        pipeline.onOverlay = { [weak self] state in self?.receive(state) }
        pipeline.onConfigured = { [weak self] info in
            guard let self else { return }
            self.info = info
            self.phase = info == nil ? .failed : .running
        }
        pipeline.setAspect(aspect)
        pipeline.configure()
        startMotion()
    }

    private func receive(_ state: OverlayState) {
        let frame = state.frame
        if let frame, frame.id != lastFrameId {
            lightHaptic.impactOccurred(intensity: 0.6)
            pipeline.focus(at: frame.subject)
        }
        lastFrameId = frame?.id

        let aligned = frame?.aligned ?? false
        if aligned && !wasAligned { successHaptic.notificationOccurred(.success) }
        wasAligned = aligned

        if live.overlay != state { live.overlay = state }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            self.handleGravity(g)
        }
    }

    private func handleGravity(_ g: CMAcceleration) {
        let ux = -g.x, uy = g.y
        let length = (ux * ux + uy * uy).squareRoot()
        let flat = abs(g.z) > 0.85 || length < 0.1

        if !flat {
            let candidate: UpDirection
            if abs(uy) >= abs(ux) {
                candidate = uy < 0 ? .top : .bottom
            } else {
                candidate = ux > 0 ? .right : .left
            }
            let strength = max(abs(ux), abs(uy)) / length
            if candidate != up, strength > 0.8 {
                up = candidate
                pipeline.setUp(candidate)
            }
        }

        var level = LevelState()
        if !flat {
            let angle = atan2(uy, ux) + .pi / 2
            let cardinal = (angle / (.pi / 2)).rounded() * (.pi / 2)
            let tilt = angle - cardinal
            level = LevelState(visible: abs(tilt) < 0.21, angle: angle, tilt: tilt)
        }
        if live.level != level { live.level = level }
    }

    func shoot() {
        guard !busy, phase == .running else { return }
        busy = true
        shutterHaptic.impactOccurred()

        let frame = live.overlay.frame
        var crop: CGRect?
        if let frame, frame.visible > 0.6 {
            let r = frame.rect.intersection(.unit)
            if r.iou(.unit) < 0.96 { crop = r }
        }
        let label = frame?.label ?? ""

        pipeline.capture(crop: crop, rotation: PhotoRotation(up: up), saveOriginal: saveOriginal,
                         willCapture: { [weak self] in self?.blink() },
                         completion: { [weak self] image, ok in
            guard let self else { return }
            self.busy = false
            if ok {
                if let image { self.thumbnail = image }
                self.show(crop == nil ? "Сохранено в «Фото»" : "Сохранено · кроп \(label)")
            } else {
                self.show("Не сохранилось — разреши доступ к «Фото» в Настройках")
            }
        })
    }

    private func blink() {
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.easeOut(duration: 0.25)) { self.flash = false }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.toast == text { withAnimation { self.toast = nil } }
        }
    }

    func selectZoom(_ factor: CGFloat) {
        pipeline.setZoom(factor, animated: true)
    }

    func pinchChanged(_ magnification: CGFloat) {
        guard let info else { return }
        if pinchBase == nil { pinchBase = live.overlay.zoom * info.baseZoom }
        pipeline.setZoom((pinchBase ?? info.baseZoom) * magnification, animated: false)
    }

    func pinchEnded() {
        pinchBase = nil
    }

    var fitMultiplier: CGFloat? {
        guard let frame = live.overlay.frame, !frame.aligned else { return nil }
        return min(1 / max(frame.rect.width, 0.05), 1 / max(frame.rect.height, 0.05)) * 0.97
    }

    func fitToFrame() {
        guard let info, let k = fitMultiplier else { return }
        pipeline.setZoom(live.overlay.zoom * info.baseZoom * k, animated: true)
        mediumHaptic.impactOccurred()
    }

    func toggleLock() {
        guard live.overlay.frame != nil else { return }
        pipeline.toggleLock()
        mediumHaptic.impactOccurred()
    }

    func tap(at point: CGPoint) {
        if let frame = live.overlay.frame, frame.rect.contains(point) {
            toggleLock()
            return
        }
        pipeline.focus(at: point)
        lightHaptic.impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) { focusMarker = point }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if self.focusMarker == point { withAnimation { self.focusMarker = nil } }
        }
    }
}
