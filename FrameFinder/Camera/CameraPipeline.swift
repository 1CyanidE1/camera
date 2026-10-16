import AVFoundation
import CoreImage
import UIKit
import Vision

struct CameraInfo {
    var baseZoom: CGFloat
    var minZoom: CGFloat
    var maxZoom: CGFloat
    var presets: [CGFloat]
    var imageAspect: CGFloat
}

final class CameraPipeline: NSObject {
    let session = AVCaptureSession()

    var onOverlay: ((OverlayState) -> Void)?
    var onConfigured: ((CameraInfo?) -> Void)?

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var baseZoom: CGFloat = 1
    private var maxZoom: CGFloat = 10
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]

    private let tracker = MotionTracker()
    private let analyzer = SceneAnalyzer()
    private let engine = CompositionEngine()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastZoom: CGFloat = 0
    private var lastZoomChange: CFTimeInterval = 0
    private var lastAnalysis: CFTimeInterval = 0
    private var lastAesthetics: CFTimeInterval = 0
    private var aestheticsBusy = false
    private var aestheticsFailures = 0

    private let analysisInterval: CFTimeInterval = 0.15
    private let aestheticsInterval: CFTimeInterval = 0.7

    func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let info = self.setUpSession()
            if info != nil { self.session.startRunning() }
            DispatchQueue.main.async { self.onConfigured?(info) }
        }
    }

    private func setUpSession() -> CameraInfo? {
        guard let device = Self.findCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return nil
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return nil
        }
        session.addOutput(videoOutput)
        session.addOutput(photoOutput)

        if !Self.selectFormat(for: device), session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()

        if let biggest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = biggest
        }

        let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let base: CGFloat = hasUltraWide ? (switchOver.first ?? 1) : 1
        let maxZoom = min(device.maxAvailableVideoZoomFactor, base * 25)
        var presets: [CGFloat] = hasUltraWide ? [device.minAvailableVideoZoomFactor, base] : [base]
        presets += switchOver.filter { $0 > base + 0.01 }
        if !presets.contains(where: { $0 > base * 1.5 && $0 < base * 2.5 }) {
            presets.append(base * 2)
        }
        presets = presets.filter { $0 <= maxZoom }.sorted()

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = base
            device.unlockForConfiguration()
        } catch {}

        self.device = device
        self.baseZoom = base
        self.maxZoom = maxZoom

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let aspect = CGFloat(min(dims.width, dims.height)) / CGFloat(max(dims.width, dims.height))
        return CameraInfo(baseZoom: base, minZoom: device.minAvailableVideoZoomFactor, maxZoom: maxZoom,
                          presets: presets, imageAspect: aspect)
    }

    private static func findCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        for type in types {
            if let d = found.first(where: { $0.deviceType == type }) { return d }
        }
        return AVCaptureDevice.default(for: .video)
    }

    private static func selectFormat(for device: AVCaptureDevice) -> Bool {
        func photoArea(_ f: AVCaptureDevice.Format) -> Int {
            f.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        func rank(_ f: AVCaptureDevice.Format) -> (Int, Int, Int) {
            let w = Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width)
            return (w <= 2112 ? 1 : 0, photoArea(f), -abs(w - 1920))
        }
        let usable = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && Int(d.width) * 3 == Int(d.height) * 4
                && d.width >= 1280
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        guard let best = usable.max(by: { rank($0) < rank($1) }) else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    func setAspect(_ mode: AspectMode) { videoQueue.async { self.engine.aspectMode = mode } }
    func setUp(_ up: UpDirection) { videoQueue.async { self.engine.up = up } }
    func toggleLock() { videoQueue.async { self.engine.locked.toggle() } }

    func setZoom(_ factor: CGFloat, animated: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let z = min(max(factor, device.minAvailableVideoZoomFactor), self.maxZoom)
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: z, withRate: 3)
                } else {
                    device.videoZoomFactor = z
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            let p = CGPoint(x: min(max(point.y, 0), 1), y: min(max(1 - point.x, 0), 1))
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = p
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = p
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func capture(crop: CGRect?, rotation: PhotoRotation, saveOriginal: Bool,
                 willCapture: @escaping () -> Void,
                 completion: @escaping (ProcessedShot?, Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, self.photoOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { completion(nil, false) }
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .balanced

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(crop: crop, rotation: rotation, saveOriginal: saveOriginal,
                                                  willCapture: willCapture, completion: completion) { [weak self] in
                self?.sessionQueue.async { [weak self] in self?.inFlight[id] = nil }
            }
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func runAesthetics(on pixelBuffer: CVPixelBuffer, now: CFTimeInterval) {
        let jobs = engine.aestheticJobs(now: now)
        guard !jobs.isEmpty else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 720 / max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent.integral) else { return }

        aestheticsBusy = true
        lastAesthetics = now
        Task.detached(priority: .utility) { [weak self] in
            var results: [(Int, Double)] = []
            var failed = false
            let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
            for job in jobs {
                let r = CGRect(x: job.rect.minX * w, y: job.rect.minY * h,
                               width: job.rect.width * w, height: job.rect.height * h).integral
                guard let crop = cgImage.cropping(to: r) else { continue }
                do {
                    let observation = try await CalculateImageAestheticsScoresRequest().perform(on: crop)
                    results.append((job.key, (Double(observation.overallScore) + 1) / 2))
                } catch {
                    failed = true
                }
            }
            let finalResults = results
            let didFail = failed
            self?.videoQueue.async { [weak self] in
                guard let self = self else { return }
                for (key, score) in finalResults { self.engine.setAesthetic(key: key, score: score) }
                if didFail { self.aestheticsFailures += 1 }
                self.aestheticsBusy = false
            }
        }
    }
}

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        engine.imageAspect = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(CVPixelBufferGetHeight(pixelBuffer))

        let zoom = device?.videoZoomFactor ?? 1
        if lastZoom > 0, abs(zoom / lastZoom - 1) > 0.0005 {
            engine.applyZoom(Double(zoom / lastZoom))
            tracker.reset()
            lastZoomChange = now
        } else {
            let shift = tracker.update(pixelBuffer)
            if shift.dx != 0 || shift.dy != 0 {
                engine.applyShift(dx: shift.dx, dy: shift.dy)
            }
        }
        lastZoom = zoom

        if now - lastAnalysis >= analysisInterval, now - lastZoomChange > 0.12 {
            lastAnalysis = now
            if let scene = analyzer.analyze(pixelBuffer) {
                engine.ingest(scene, now: now)
            }
            if now - lastAesthetics >= aestheticsInterval, !aestheticsBusy, aestheticsFailures < 5 {
                runAesthetics(on: pixelBuffer, now: now)
            }
        }

        var state = OverlayState()
        state.frame = engine.overlayFrame()
        state.zoom = zoom / baseZoom
        let callback = onOverlay
        DispatchQueue.main.async { callback?(state) }
    }
}
