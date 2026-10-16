import AVFoundation
import CoreMotion
import SwiftUI
import UIKit

enum ProControl {
    case focus, iso, shutter
}

struct FocusMarker: Equatable {
    var point: CGPoint
    var locked: Bool
}

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
    @Published var focusMarker: FocusMarker?
    @Published var exposureBias: Float = 0
    @Published var adjustingBias = false
    @Published var focusMode = FocusMode(rawValue: UserDefaults.standard.string(forKey: "focusMode") ?? "") ?? .auto {
        didSet {
            UserDefaults.standard.set(focusMode.rawValue, forKey: "focusMode")
            pipeline.setFocusMode(focusMode)
            updateHardware()
            exposureBias = 0
            withAnimation(.easeOut(duration: 0.2)) {
                focusMarker = nil
                if focusMode == .manual {
                    lensPosition = live.overlay.readout.lensPosition
                    editing = .focus
                } else if editing == .focus {
                    editing = nil
                }
            }
        }
    }
    @Published var editing: ProControl?
    @Published var lensPosition: Float = 0.5
    @Published var isoPosition: Double = 0.3
    @Published var shutterPosition: Double = 0.5
    @Published var loupeOn = false
    @Published var assist = AssistOptions(
        zebra: UserDefaults.standard.bool(forKey: "zebra"),
        peaking: UserDefaults.standard.bool(forKey: "peaking"),
        histogram: UserDefaults.standard.object(forKey: "histogram") as? Bool ?? true
    ) {
        didSet {
            UserDefaults.standard.set(assist.zebra, forKey: "zebra")
            UserDefaults.standard.set(assist.peaking, forKey: "peaking")
            UserDefaults.standard.set(assist.histogram, forKey: "histogram")
            pipeline.setAssist(assist)
        }
    }
    @Published var showGallery = false {
        didSet {
            guard showGallery != oldValue else { return }
            if showGallery {
                pipeline.pause()
                motion.stopDeviceMotionUpdates()
            } else {
                pipeline.resume()
                startMotion()
            }
        }
    }
    @Published var captureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .standard {
        didSet {
            UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode")
            if captureMode != oldValue { pipeline.setCaptureMode(captureMode) }
        }
    }
    @Published var autoShutter = UserDefaults.standard.bool(forKey: "autoShutter") {
        didSet {
            UserDefaults.standard.set(autoShutter, forKey: "autoShutter")
            pipeline.setFaceQuality(autoShutter)
            countdownStart = nil
            firedFrameId = nil
            if autoProgress != nil { autoProgress = nil }
        }
    }
    @Published var autoProgress: Double?
    @Published var neuralAvailable = false
    @Published var neuralFraming = UserDefaults.standard.object(forKey: "neuralFraming") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(neuralFraming, forKey: "neuralFraming")
            pipeline.setNeuralFraming(neuralFraming)
        }
    }
    @Published var explain = UserDefaults.standard.bool(forKey: "explain") {
        didSet { UserDefaults.standard.set(explain, forKey: "explain") }
    }

    let live = LiveState()
    let pipeline = CameraPipeline()
    let shots = ShotStore()

    private let motion = CMMotionManager()
    private var up: UpDirection = .top
    private var started = false
    private var pinchBase: CGFloat?
    private var manualExposureActive = false
    private var customISO: Double?
    private var customDuration: Double?
    private var lastFrameId: Int?
    private var wasAligned = false
    private var biasStart: Float = 0
    private var steadySince: CFTimeInterval?
    private var lastMotionTime: CFTimeInterval = 0
    private var frameSince: (id: Int, time: CFTimeInterval)?
    private var countdownStart: CFTimeInterval?
    private var firedFrameId: Int?
    private var moveSinceShot = 0.0
    private var markerToken = 0

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let shutterHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let successHaptic = UINotificationFeedbackGenerator()
    private let selectionHaptic = UISelectionFeedbackGenerator()

    init() {
        thumbnail = shots.latestThumbnail()
    }

    func refreshThumbnail() {
        thumbnail = shots.latestThumbnail()
    }

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
            if let info, info.mode == .raw, !info.rawAvailable {
                self.show("ProRAW на этой камере недоступен")
                self.captureMode = .standard
            }
            guard let info else { return }
            if info.mode == .standard, self.needsPhysical != info.manualHardware {
                self.updateHardware()
                return
            }
            if self.focusMode == .manual, info.manualHardware || info.mode == .raw, !info.limits.supportsManualFocus {
                self.show("Ручной фокус на этом объективе недоступен")
                self.focusMode = .auto
            }
            if self.manualExposureActive, self.customISO != nil || self.customDuration != nil {
                self.pipeline.setManualExposure(iso: self.customISO.map { Float($0) }, duration: self.customDuration)
            }
        }
        pipeline.setAspect(aspect)
        pipeline.setFocusMode(focusMode)
        pipeline.setAssist(assist)
        pipeline.setFaceQuality(autoShutter)
        pipeline.onNeuralAvailability = { [weak self] ready in self?.neuralAvailable = ready }
        pipeline.setNeuralFraming(neuralFraming)
        pipeline.configure(mode: captureMode)
        startMotion()
    }

    private func receive(_ state: OverlayState) {
        let frame = state.frame
        if let frame, frame.id != lastFrameId {
            lightHaptic.impactOccurred(intensity: 0.6)
        }
        lastFrameId = frame?.id

        let aligned = frame?.aligned ?? false
        if aligned && !wasAligned { successHaptic.notificationOccurred(.success) }
        wasAligned = aligned

        if live.overlay != state { live.overlay = state }
        evaluateAutoShutter(state)
    }

    private func evaluateAutoShutter(_ state: OverlayState) {
        let now = CACurrentMediaTime()
        guard autoShutter, phase == .running, !busy, !showGallery, editing == nil, let frame = state.frame else {
            cancelCountdown()
            return
        }
        if frameSince?.id != frame.id { frameSince = (frame.id, now) }
        if let fired = firedFrameId {
            if frame.id != fired || moveSinceShot > 0.35 {
                firedFrameId = nil
            } else {
                cancelCountdown()
                return
            }
        }
        let steady = steadySince.map { now - $0 >= 0.6 } ?? false
        let ready = now - (frameSince?.time ?? now) >= 1.2
            && frame.visible >= 0.9
            && steady
            && !state.readout.adjustingFocus
            && !state.readout.adjustingExposure
            && state.faceOK
        guard ready else {
            cancelCountdown()
            return
        }
        let start = countdownStart ?? now
        countdownStart = start
        let progress = (now - start) / 1.5
        if progress >= 1 {
            cancelCountdown()
            firedFrameId = frame.id
            moveSinceShot = 0
            shoot()
        } else if abs((autoProgress ?? -1) - progress) > 0.02 {
            autoProgress = progress
        }
    }

    private func cancelCountdown() {
        countdownStart = nil
        if autoProgress != nil { autoProgress = nil }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.handleRotation(data.rotationRate)
            self.handleGravity(data.gravity)
        }
    }

    private func handleRotation(_ rate: CMRotationRate) {
        let now = CACurrentMediaTime()
        let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
        if lastMotionTime > 0 { moveSinceShot += speed * min(now - lastMotionTime, 0.2) }
        lastMotionTime = now
        if speed < 0.08 {
            if steadySince == nil { steadySince = now }
        } else {
            steadySince = nil
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
        let label = crop == nil ? "Целиком" : (frame?.label ?? "")
        let rotation = PhotoRotation(up: up)
        let id = UUID()
        let draft = ShotRecord(id: id, date: Date(), label: label,
                               aesthetic: crop == nil ? nil : frame?.aesthetic,
                               crop: crop.map { up.toUpright($0) },
                               reasons: crop == nil ? [] : (frame?.reasons ?? []),
                               rotation: rotation)

        pipeline.capture(crop: crop, rotation: rotation, saveOriginal: saveOriginal,
                         willCapture: { [weak self] in self?.blink() },
                         completion: { [weak self] shot, savedToPhotos in
            guard let self else { return }
            self.busy = false
            guard let shot else {
                self.show("Не удалось обработать снимок")
                return
            }
            var record = draft
            record.source = ShotSource(file: ShotRecord.sourceFile(for: id, kind: shot.sourceKind), kind: shot.sourceKind)
            self.shots.add(record, viewer: shot.viewer, original: shot.original, source: shot.source)
            if let image = shot.thumbnail { self.thumbnail = image }
            if shot.sourceKind == .proRAW {
                self.show("RAW 48 Мп — в галерее приложения")
            } else if savedToPhotos {
                self.show(crop == nil ? "Сохранено" : "Сохранено · кадр \(label)")
            } else {
                self.show("Снимок в приложении, но не в «Фото» — разреши доступ в Настройках")
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
        pipeline.tapFocus(at: point)
        lightHaptic.impactOccurred()
        exposureBias = 0
        showMarker(FocusMarker(point: point, locked: false))
    }

    func longPress(at point: CGPoint) {
        pipeline.lockFocus(at: point)
        mediumHaptic.impactOccurred()
        exposureBias = 0
        showMarker(FocusMarker(point: point, locked: true))
    }

    func unlockFocus() {
        pipeline.unlockFocus()
        withAnimation(.easeOut(duration: 0.2)) { focusMarker = nil }
    }

    var canAdjustBias: Bool { focusMarker != nil }

    func biasDrag(_ translation: CGFloat, ended: Bool) {
        if !adjustingBias {
            adjustingBias = true
            biasStart = exposureBias
        }
        let value = min(max(biasStart - Float(translation / 110), -2), 2)
        let stepped = (value * 10).rounded() / 10
        if stepped != exposureBias {
            exposureBias = stepped
            pipeline.setExposureBias(stepped)
            if stepped == 0 { selectionHaptic.selectionChanged() }
        }
        if ended {
            adjustingBias = false
            if let marker = focusMarker { showMarker(marker) }
        }
    }

    private func showMarker(_ marker: FocusMarker) {
        withAnimation(.easeOut(duration: 0.15)) { focusMarker = marker }
        markerToken += 1
        let token = markerToken
        guard !marker.locked else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard self.markerToken == token, !self.adjustingBias else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.focusMarker = nil }
        }
    }

    private var needsPhysical: Bool {
        focusMode == .manual || manualExposureActive
    }

    private func updateHardware() {
        guard captureMode == .standard else { return }
        pipeline.setPhysicalMode(needsPhysical)
    }

    func selectLens(_ type: AVCaptureDevice.DeviceType) {
        pipeline.setPhysicalLens(type)
        selectionHaptic.selectionChanged()
    }

    func edit(_ control: ProControl) {
        guard let limits = info?.limits else { return }
        if control != .focus, !manualExposureActive {
            manualExposureActive = true
            updateHardware()
        }
        let r = live.overlay.readout
        switch control {
        case .iso:
            isoPosition = Self.position(Double(r.iso), Double(limits.minISO), Double(limits.maxISO))
        case .shutter:
            shutterPosition = Self.position(r.duration, limits.minDuration, limits.maxDuration)
        case .focus:
            lensPosition = r.lensPosition
        }
        withAnimation(.easeInOut(duration: 0.2)) { editing = editing == control ? nil : control }
    }

    func setISOPosition(_ t: Double) {
        isoPosition = t
        guard let limits = info?.limits else { return }
        let iso = Self.value(t, Double(limits.minISO), Double(limits.maxISO))
        customISO = iso
        pipeline.setManualExposure(iso: Float(iso), duration: customDuration)
    }

    func setShutterPosition(_ t: Double) {
        shutterPosition = t
        guard let limits = info?.limits else { return }
        let duration = Self.value(t, limits.minDuration, limits.maxDuration)
        customDuration = duration
        pipeline.setManualExposure(iso: customISO.map { Float($0) }, duration: duration)
    }

    func autoExposure() {
        manualExposureActive = false
        customISO = nil
        customDuration = nil
        pipeline.setAutoExposure()
        updateHardware()
        selectionHaptic.selectionChanged()
        withAnimation(.easeInOut(duration: 0.2)) { editing = nil }
    }

    func setLens(_ position: Float) {
        lensPosition = position
        pipeline.setLensPosition(position)
    }

    func lensEditing(_ active: Bool) {
        pipeline.setForcePeaking(active)
        pipeline.setLoupe(active ? (focusMarker?.point ?? CGPoint(x: 0.5, y: 0.5)) : nil)
        withAnimation(.easeOut(duration: 0.15)) { loupeOn = active }
    }

    private static func position(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo, v > 0, lo > 0 else { return 0.5 }
        return min(max(log(v / lo) / log(hi / lo), 0), 1)
    }

    private static func value(_ t: Double, _ lo: Double, _ hi: Double) -> Double {
        lo * pow(hi / lo, t)
    }
}
