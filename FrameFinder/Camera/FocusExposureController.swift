import AVFoundation
import QuartzCore

enum FocusMode: String, CaseIterable, Identifiable {
    case auto, continuous, single, manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .continuous: return "AF-C"
        case .single: return "AF-S"
        case .manual: return "MF"
        }
    }
}

struct CameraReadout: Equatable {
    var iso: Float = 0
    var duration: Double = 0
    var bias: Float = 0
    var lensPosition: Float = 0
    var adjustingFocus = false
    var adjustingExposure = false
    var manualExposure = false
}

struct ExposureLimits: Equatable {
    var minISO: Float = 50
    var maxISO: Float = 3200
    var minDuration: Double = 1.0 / 8000
    var maxDuration: Double = 1.0 / 3
    var supportsManualFocus = false
}

final class FocusExposureController {
    private var device: AVCaptureDevice?
    private(set) var mode: FocusMode = .auto
    private(set) var locked = false
    private var trackingPausedUntil: CFTimeInterval = 0
    private var lastTracked: CGPoint?
    private var lastTrackTime: CFTimeInterval = 0
    private(set) var manualExposure = false

    var limits: ExposureLimits {
        guard let d = device else { return ExposureLimits() }
        let format = d.activeFormat
        return ExposureLimits(minISO: format.minISO,
                              maxISO: format.maxISO,
                              minDuration: max(format.minExposureDuration.seconds, 1.0 / 16000),
                              maxDuration: min(format.maxExposureDuration.seconds, 1.0),
                              supportsManualFocus: d.isLockingFocusWithCustomLensPositionSupported)
    }

    func attach(_ device: AVCaptureDevice) {
        self.device = device
        configure { d in
            d.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
            d.isFaceDrivenAutoFocusEnabled = false
            d.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            d.isFaceDrivenAutoExposureEnabled = false
        }
        setMode(mode)
    }

    func setMode(_ newMode: FocusMode) {
        mode = newMode
        locked = false
        lastTracked = nil
        configure { d in
            if d.isVirtualDevice {
                let behavior: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior = newMode == .manual ? .locked : .auto
                if d.primaryConstituentDeviceSwitchingBehavior != behavior {
                    d.setPrimaryConstituentDeviceSwitchingBehavior(behavior, restrictedSwitchingBehaviorConditions: [])
                }
            }
            switch newMode {
            case .auto, .continuous:
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            case .single:
                if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            case .manual:
                if d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(lensPosition: d.lensPosition, completionHandler: nil)
                } else if d.isFocusModeSupported(.locked) {
                    d.focusMode = .locked
                }
            }
            if d.exposureMode != .custom, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    func tap(at point: CGPoint, now: CFTimeInterval) {
        locked = false
        trackingPausedUntil = now + 6
        let p = Self.devicePoint(point)
        let focusMode: AVCaptureDevice.FocusMode = mode == .single ? .autoFocus : .continuousAutoFocus
        configure { d in
            if self.mode != .manual, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(focusMode) {
                d.focusPointOfInterest = p
                d.focusMode = focusMode
            }
            if d.exposureMode != .custom, d.isExposurePointOfInterestSupported,
               d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = p
                d.exposureMode = .continuousAutoExposure
                d.setExposureTargetBias(0, completionHandler: nil)
            }
        }
    }

    func lock(at point: CGPoint) {
        locked = true
        let p = Self.devicePoint(point)
        configure { d in
            if self.mode != .manual, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = p
                d.focusMode = .autoFocus
            }
            if d.exposureMode != .custom, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                d.exposurePointOfInterest = p
                d.exposureMode = .autoExpose
                d.setExposureTargetBias(0, completionHandler: nil)
            }
        }
    }

    func unlock() {
        setMode(mode)
    }

    func setLensPosition(_ position: Float) {
        guard mode == .manual else { return }
        configure { d in
            if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            }
        }
    }

    func setManualExposure(iso: Float?, duration: Double?) {
        configure { d in
            guard d.isExposureModeSupported(.custom) else { return }
            let format = d.activeFormat
            let targetISO = min(max(iso ?? d.iso, format.minISO), format.maxISO)
            let seconds = min(max(duration ?? d.exposureDuration.seconds, format.minExposureDuration.seconds),
                              format.maxExposureDuration.seconds)
            d.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                    iso: targetISO, completionHandler: nil)
            self.manualExposure = true
        }
    }

    func setAutoExposure() {
        manualExposure = false
        configure { d in
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        }
    }

    func setBias(_ ev: Float) {
        configure { d in
            let value = min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias)
            d.setExposureTargetBias(value, completionHandler: nil)
        }
    }

    func track(_ point: CGPoint, now: CFTimeInterval) {
        guard mode == .auto, !locked, now >= trackingPausedUntil, now - lastTrackTime > 0.33 else { return }
        if let last = lastTracked, hypot(point.x - last.x, point.y - last.y) < 0.04, now - lastTrackTime < 2 { return }
        lastTracked = point
        lastTrackTime = now
        let p = Self.devicePoint(point)
        configure { d in
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = p
                d.focusMode = .continuousAutoFocus
            }
            if d.exposureMode != .custom, d.isExposurePointOfInterestSupported,
               d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = p
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    static func readout(of device: AVCaptureDevice) -> CameraReadout {
        CameraReadout(iso: device.iso,
                      duration: device.exposureDuration.seconds,
                      bias: device.exposureTargetBias,
                      lensPosition: device.lensPosition,
                      adjustingFocus: device.isAdjustingFocus,
                      adjustingExposure: device.isAdjustingExposure,
                      manualExposure: device.exposureMode == .custom)
    }

    private func configure(_ body: (AVCaptureDevice) -> Void) {
        guard let d = device else { return }
        do {
            try d.lockForConfiguration()
            body(d)
            d.unlockForConfiguration()
        } catch {}
    }

    private static func devicePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.y, 0), 1), y: min(max(1 - p.x, 0), 1))
    }
}
