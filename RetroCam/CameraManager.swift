import AVFoundation
import Vision
import Photos
import CoreImage
import UIKit

enum CameraAuth { case unknown, authorized, denied }

/// Contenitore del solo frame di anteprima: così il mirino si aggiorna a 30 fps
/// senza ridisegnare tutta l'interfaccia.
final class PreviewModel: ObservableObject {
    @Published var image: CGImage?
}

/// Gestisce sessione di cattura, rendering live dei filtri, maschera persona, messa a fuoco manuale e salvataggio.
/// NB: in Xcode 26+ imposta "Default Actor Isolation = nonisolated" (Build Settings) per questo target,
/// oppure Swift Language Mode 5. Il progetto incluso è già configurato così.
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: Stato per la UI
    let preview = PreviewModel()
    @Published var lastPhoto: UIImage?
    @Published var hudText = "ƒ/1.8 · 1/125 · ISO 200"
    @Published var saveCounter = 0
    @Published var recipe: CameraRecipe = CameraRecipe.all[0] { didSet { syncRenderState() } }
    @Published var flashEnabled = true { didSet { syncRenderState() } }
    @Published var manualFocus = false
    @Published var lensPosition: Float = 0.6        // 0 = vicino ... 1 = infinito
    @Published var maxDiopters: Float = 10          // da minimumFocusDistance
    @Published var zoom: CGFloat = 1
    @Published var exposureBias: Float = 0          // -2...+2 EV
    @Published var authorization: CameraAuth = .unknown
    @Published var isFront = false
    @Published var pendingCount = 0                 // scatti in elaborazione
    @Published var toast: String?

    var isProcessing: Bool { pendingCount > 0 }

    // MARK: Interni
    private let engine = FilterEngine()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "retrocam.session")
    private let videoQueue = DispatchQueue(label: "retrocam.video")
    private let maskQueue = DispatchQueue(label: "retrocam.mask")
    private let processQueue = DispatchQueue(label: "retrocam.process", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    // Accessibili solo da sessionQueue
    private var configured = false
    private var currentInput: AVCaptureDeviceInput?

    // Protetti da stateLock (letti anche dalla coda video)
    private let stateLock = NSLock()
    private var _device: AVCaptureDevice?
    private var renderRecipe = CameraRecipe.all[0]
    private var renderFlash = true
    private var latestMask: CIImage?
    private var isMasking = false
    private var manualActive = false
    private var frameCount = 0

    private var device: AVCaptureDevice? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _device }
        set { stateLock.lock(); _device = newValue; stateLock.unlock() }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.resetToContinuous() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func syncRenderState() {
        stateLock.lock(); renderRecipe = recipe; renderFlash = flashEnabled; stateLock.unlock()
    }
    private func snapshot() -> (CameraRecipe, Bool, CIImage?) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (renderRecipe, renderFlash, latestMask)
    }

    private func setAuth(_ a: CameraAuth) {
        DispatchQueue.main.async { self.authorization = a }
    }

    // MARK: Avvio / stop
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setAuth(.authorized); configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                self.setAuth(ok ? .authorized : .denied)
                if ok { self.configureAndRun() }
            }
        default:
            setAuth(.denied)
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func camera(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func configureConnections(front: Bool) {
        if let c = videoOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = front }
        }
        if let c = photoOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
    }

    private func publishDeviceInfo(_ dev: AVCaptureDevice) {
        let minFocus = dev.minimumFocusDistance          // mm, -1 se sconosciuto
        let diopters: Float = minFocus > 0 ? 1000 / Float(minFocus) : 10
        DispatchQueue.main.async { self.maxDiopters = diopters }
    }

    private func configureAndRun() {
        sessionQueue.async { [self] in
            if configured {
                if !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let dev = camera(.back),
                  let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
                session.commitConfiguration(); return
            }
            session.addInput(input); device = dev; currentInput = input

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            configureConnections(front: false)
            session.commitConfiguration()
            configured = true

            publishDeviceInfo(dev)
            installSystemControls(for: dev)
            session.startRunning()
        }
    }

    // MARK: Camera Control (iPhone 16 e successivi)
    /// Slider di zoom ed esposizione sul tasto Camera Control. Da chiamare sulla sessionQueue.
    /// Lo scatto con la pressione del tasto è gestito in ContentView (onCameraCaptureEvent).
    private func installSystemControls(for dev: AVCaptureDevice) {
        guard #available(iOS 18.0, *), session.supportsControls else { return }
        for control in session.controls { session.removeControl(control) }
        session.setControlsDelegate(self, queue: sessionQueue)

        // Le action girano sul main actor e tengono allineata l'interfaccia (pillola zoom, cursore esposizione)
        let zoomSlider = AVCaptureSystemZoomSlider(device: dev) { [weak self] factor in
            self?.zoom = factor
        }
        let biasSlider = AVCaptureSystemExposureBiasSlider(device: dev) { [weak self] bias in
            self?.exposureBias = bias
        }
        for control in [zoomSlider, biasSlider] where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    // MARK: Fotocamera frontale / posteriore
    func flipCamera() {
        sessionQueue.async { [self] in
            guard configured, let oldInput = currentInput else { return }
            let toFront = (device?.position ?? .back) == .back
            guard let dev = camera(toFront ? .front : .back),
                  let input = try? AVCaptureDeviceInput(device: dev) else { return }

            session.beginConfiguration()
            session.removeInput(oldInput)
            var switched = false
            if session.canAddInput(input) {
                session.addInput(input); currentInput = input; device = dev; switched = true
            } else {
                session.addInput(oldInput)
            }
            configureConnections(front: (device?.position ?? .back) == .front)
            session.commitConfiguration()
            guard switched else { return }

            stateLock.lock(); latestMask = nil; manualActive = false; stateLock.unlock()
            publishDeviceInfo(dev)
            DispatchQueue.main.async {
                self.isFront = toFront
                self.zoom = 1
                self.manualFocus = false
                self.exposureBias = 0
            }
        }
    }

    // MARK: Scatto
    func capturePhoto() {
        DispatchQueue.main.async { self.pendingCount += 1 }
        sessionQueue.async { [self] in
            guard session.isRunning else { finishOne(toast: "Fotocamera non disponibile."); return }
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    private func finishOne(toast message: String? = nil) {
        DispatchQueue.main.async {
            self.pendingCount = max(0, self.pendingCount - 1)
            if let message { self.toast = message }
        }
    }

    // MARK: Messa a fuoco
    func setManualFocus(_ on: Bool) {
        let lp = lensPosition
        sessionQueue.async { [self] in
            guard let d = device else { return }
            var applied = false
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                if on {
                    if d.isLockingFocusWithCustomLensPositionSupported {
                        d.setFocusModeLocked(lensPosition: lp)
                        applied = true
                    }
                } else if d.isFocusModeSupported(.continuousAutoFocus) {
                    d.focusMode = .continuousAutoFocus
                }
            } catch { }
            let result = on && applied
            stateLock.lock(); manualActive = result; stateLock.unlock()
            DispatchQueue.main.async { self.manualFocus = result }
        }
    }

    /// Applica al device la posizione della ghiera (il binding aggiorna già `lensPosition`).
    func applyLensPosition(_ p: Float) {
        sessionQueue.async { [self] in
            guard let d = device, d.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                d.setFocusModeLocked(lensPosition: min(1, max(0, p)))
            } catch { }
        }
    }

    /// Tap-to-focus. `devicePoint`: coordinate normalizzate del sensore (vedi ContentView).
    func focus(atDevicePoint p: CGPoint) {
        sessionQueue.async { [self] in
            guard let d = device else { return }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p; d.focusMode = .autoFocus }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p; d.exposureMode = .continuousAutoExposure }
                d.isSubjectAreaChangeMonitoringEnabled = true
            } catch { }
        }
    }

    /// Quando la scena cambia dopo un tap-to-focus, torna all'autofocus continuo al centro.
    private func resetToContinuous() {
        sessionQueue.async { [self] in
            stateLock.lock(); let manual = manualActive; stateLock.unlock()
            guard !manual, let d = device else { return }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                let center = CGPoint(x: 0.5, y: 0.5)
                if d.isFocusModeSupported(.continuousAutoFocus) {
                    if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = center }
                    d.focusMode = .continuousAutoFocus
                }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = center }
                d.isSubjectAreaChangeMonitoringEnabled = false
            } catch { }
        }
    }

    // MARK: Zoom ed esposizione
    func setZoom(_ f: CGFloat, ramp: Bool = true) {
        sessionQueue.async { [self] in
            guard let d = device else { return }
            let upper = min(d.activeFormat.videoMaxZoomFactor, 10)
            let target = min(max(f, d.minAvailableVideoZoomFactor), upper)
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                if ramp {
                    d.ramp(toVideoZoomFactor: target, withRate: 6)
                } else {
                    d.cancelVideoZoomRamp()
                    d.videoZoomFactor = target
                }
            } catch { }
            DispatchQueue.main.async { self.zoom = target }
        }
    }

    func setExposureBias(_ value: Float) {
        let clamped = min(2, max(-2, value))
        DispatchQueue.main.async { self.exposureBias = clamped }
        sessionQueue.async { [self] in
            guard let d = device else { return }
            let b = min(d.maxExposureTargetBias, max(d.minExposureTargetBias, clamped))
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                d.setExposureTargetBias(b, completionHandler: nil)
            } catch { }
        }
    }

    // MARK: Maschera persona (Vision)
    private func scheduleMask(_ pb: CVPixelBuffer) {
        stateLock.lock()
        if isMasking { stateLock.unlock(); return }
        isMasking = true
        stateLock.unlock()
        maskQueue.async { [self] in
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .fast                         // ~10 ms, adatta al live
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
            let m = req.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
            stateLock.lock(); latestMask = m; isMasking = false; stateLock.unlock()
        }
    }

    private func personMask(for image: CIImage) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(ciImage: image).perform([req])
        return req.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
    }

    // MARK: Salvataggio
    private func save(_ jpeg: Data, original: Data?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
            guard status == .authorized || status == .limited else {
                finishOne(toast: "Consenti l'accesso alle Foto in Impostazioni per salvare gli scatti.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                // L'originale viene aggiunto per primo: lo scatto filtrato resta il più recente in libreria
                if let original {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: original, options: nil)
                }
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
            }) { ok, _ in
                guard ok else { self.finishOne(toast: "Salvataggio non riuscito."); return }
                let thumb = UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 160, height: 160))
                DispatchQueue.main.async {
                    self.lastPhoto = thumb
                    self.saveCounter += 1
                    self.pendingCount = max(0, self.pendingCount - 1)
                }
            }
        }
    }
}

// MARK: - Camera Control: stato dei controlli
/// Obbligatorio perché i controlli diventino attivi; la nostra interfaccia non ha bisogno di reagire.
@available(iOS 18.0, *)
extension CameraManager: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

// MARK: - Frame video → anteprima filtrata
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let (rec, flash, mask) = snapshot()
        if rec.flash != nil && flash { scheduleMask(pb) }

        let out = engine.render(CIImage(cvPixelBuffer: pb), mask: mask, recipe: rec, flashOn: flash,
                                time: CACurrentMediaTime(), quality: .preview)
        guard let cg = engine.context.createCGImage(out, from: out.extent) else { return }

        frameCount += 1
        var hud: String?
        if frameCount % 15 == 0, let d = device {
            let dur = max(d.exposureDuration.seconds, 0.0001)
            hud = String(format: "ƒ/%.1f · 1/%ld · ISO %ld", d.lensAperture, Int((1 / dur).rounded()), Int(d.iso))
        }
        DispatchQueue.main.async {
            self.preview.image = cg
            if let hud { self.hudText = hud }
        }
    }
}

// MARK: - Foto finale
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            finishOne(toast: "Scatto non riuscito. Riprova.")
            return
        }
        let keepOriginal = UserDefaults.standard.bool(forKey: "saveOriginal")

        // Una sola elaborazione alla volta: i 12 MP filtrati sono pesanti in memoria
        processQueue.async { [self] in
            autoreleasepool {
                guard let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                    finishOne(toast: "Impossibile elaborare la foto.")
                    return
                }
                let (rec, flash, _) = snapshot()
                let mask = (rec.flash != nil && flash) ? personMask(for: ci) : nil
                let out = engine.render(ci, mask: mask, recipe: rec, flashOn: flash,
                                        time: CACurrentMediaTime(), quality: .photo)
                let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let jpeg = engine.context.jpegRepresentation(
                    of: out, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [key: 0.92]) else {
                    finishOne(toast: "Impossibile elaborare la foto.")
                    return
                }
                save(jpeg, original: keepOriginal ? data : nil)
            }
        }
    }
}
