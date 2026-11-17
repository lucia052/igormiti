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
    @Published var lensStops: [CGFloat] = [1]       // zoom mostrato di ogni obiettivo fisico (es. 0.5, 1, 3)
    @Published var zoomStops: [CGFloat] = [1, 2, 4] // scatti rapidi: obiettivi fisici + tappe digitali
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
    private var lensFactors: [CGFloat] = [1]        // videoZoomFactor a cui inizia ogni obiettivo fisico
    private var lensMultiplier: CGFloat = 1         // da videoZoomFactor allo zoom mostrato (0.5 con ultra-grandangolo)
    private var swappedForManual = false            // la messa a fuoco manuale usa l'obiettivo fisico invece della virtuale
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?   // angolo di scatto secondo la posizione del telefono
    private var rotationDeviceID: String?

    // Protetti da stateLock (letti anche dalla coda video)
    private let stateLock = NSLock()
    private var _device: AVCaptureDevice?
    private var renderRecipe = CameraRecipe.all[0]
    private var renderFlash = true
    private var latestMask: CIImage?
    private var isMasking = false
    private var manualActive = false
    private var realFlashAvailable = false      // il dispositivo attivo ha un flash fisico (LED o schermo)
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

    /// Da chiamare sulla sessionQueue dopo ogni cambio di input.
    private func updateRealFlash() {
        let ok = photoOutput.supportedFlashModes.contains(.on)
        stateLock.lock(); realFlashAvailable = ok; stateLock.unlock()
    }
    private func hasRealFlash() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return realFlashAvailable
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
        // Posteriore: fotocamera virtuale con tutti gli obiettivi fisici disponibili (ultra-grandangolo, grandangolo, tele)
        if position == .back {
            for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera] {
                if let d = AVCaptureDevice.default(type, for: .video, position: .back) { return d }
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// "0,5×", "1×", "3×"
    static func lensLabel(_ z: CGFloat) -> String {
        z == z.rounded() ? "\(Int(z))×" : String(format: "%.1f×", z).replacingOccurrences(of: ".", with: ",")
    }

    /// Rotazione del mirino secondo l'interfaccia: 90 verticale, 0 orizzontale (home a destra), 180 (home a sinistra).
    private var _previewAngle: CGFloat = 90
    private func currentPreviewAngle() -> CGFloat {
        stateLock.lock(); defer { stateLock.unlock() }
        return _previewAngle
    }

    /// Da chiamare quando l'interfaccia ruota: il mirino resta dritto rispetto al mondo.
    func setInterfaceOrientation(_ o: UIInterfaceOrientation) {
        let angle: CGFloat
        switch o {
        case .landscapeRight: angle = 0
        case .landscapeLeft: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        stateLock.lock(); _previewAngle = angle; stateLock.unlock()
        sessionQueue.async { [self] in
            if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
        }
    }

    private func configureConnections(front: Bool) {
        if let c = videoOutput.connection(with: .video) {
            let angle = currentPreviewAngle()
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            // Mirino a specchio sulla frontale, come l'app Fotocamera di iOS; la foto salvata resta non specchiata
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

        // Obiettivi fisici: ogni "switch-over" è l'inizio di un obiettivo vero. Tra uno e l'altro sarebbe zoom digitale.
        let switches = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let startsWithUltraWide = dev.constituentDevices.first?.deviceType == .builtInUltraWideCamera
        var mult: CGFloat = 1
        if #available(iOS 18.0, *) {
            mult = dev.displayVideoZoomFactorMultiplier
        } else if startsWithUltraWide, let first = switches.first {
            mult = 1 / first
        }
        let factors = [CGFloat(1)] + switches
        lensFactors = factors; lensMultiplier = mult
        let stops = factors.map { (($0 * mult) * 10).rounded() / 10 }

        // Si parte dall'obiettivo principale (1×), non dall'ultra-grandangolo
        let mainFactor = startsWithUltraWide ? (switches.first ?? 1) : 1
        if (try? dev.lockForConfiguration()) != nil {
            dev.cancelVideoZoomRamp()
            dev.videoZoomFactor = min(max(mainFactor, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
            dev.unlockForConfiguration()
        }
        // Scatti rapidi: obiettivi fisici più 2× e 4× digitali se non coincidono con un obiettivo vero
        var quick = stops
        for digital in [CGFloat(2), 4] where !stops.contains(where: { abs($0 - digital) < 0.3 }) { quick.append(digital) }
        quick.sort()
        DispatchQueue.main.async { self.lensStops = stops; self.zoomStops = quick; self.zoom = 1 }
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
            updateRealFlash()

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

        // Le action girano sul main actor e tengono allineata l'interfaccia (cursore esposizione)
        let biasSlider = AVCaptureSystemExposureBiasSlider(device: dev) { [weak self] bias in
            self?.exposureBias = bias
        }
        // Zoom continuo del sistema: attraversa gli obiettivi fisici e prosegue in digitale
        let zoomSlider = AVCaptureSystemZoomSlider(device: dev) { [weak self] factor in
            guard let self else { return }
            self.zoom = ((factor * self.lensMultiplier) * 100).rounded() / 100
        }
        let controls: [AVCaptureControl] = [zoomSlider, biasSlider]
        for control in controls where session.canAddControl(control) {
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
            session.commitConfiguration()
            // Dopo il commit: le connessioni del nuovo input esistono e accettano la rotazione verticale
            configureConnections(front: (device?.position ?? .back) == .front)
            updateRealFlash()
            guard switched else { return }

            stateLock.lock(); latestMask = nil; manualActive = false; stateLock.unlock()
            swappedForManual = false
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
            let settings = AVCapturePhotoSettings()
            // Flash acceso su una fotocamera che lo prevede: si accende la luce vera (LED o schermo sulla frontale)
            let (rec, flash, _) = snapshot()
            if flash, rec.flash != nil, photoOutput.supportedFlashModes.contains(.on) {
                settings.flashMode = .on
            }
            // Foto orientata come il telefono: in orizzontale esce orizzontale
            if let d = device, let connection = photoOutput.connection(with: .video) {
                if rotationCoordinator == nil || rotationDeviceID != d.uniqueID {
                    rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)
                    rotationDeviceID = d.uniqueID
                }
                if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func finishOne(toast message: String? = nil) {
        DispatchQueue.main.async {
            self.pendingCount = max(0, self.pendingCount - 1)
            if let message { self.toast = message }
        }
    }

    // MARK: Messa a fuoco
    /// La fotocamera virtuale (più obiettivi) non permette di bloccare il fuoco su una posizione: per la messa a fuoco
    /// manuale si passa all'obiettivo fisico attivo, e si torna alla virtuale quando si riattiva l'autofocus.
    private func physicalDevice(forVirtual v: AVCaptureDevice) -> AVCaptureDevice? {
        let devices = v.constituentDevices
        guard !devices.isEmpty else { return nil }
        var index = 0
        for (i, f) in lensFactors.enumerated() where f <= v.videoZoomFactor + 0.01 { index = i }
        return devices.indices.contains(index) ? devices[index] : devices.first
    }

    /// Da chiamare sulla sessionQueue.
    private func switchInput(to newDevice: AVCaptureDevice) -> Bool {
        guard let old = currentInput, let input = try? AVCaptureDeviceInput(device: newDevice) else { return false }
        session.beginConfiguration()
        session.removeInput(old)
        var ok = false
        if session.canAddInput(input) {
            session.addInput(input); currentInput = input; device = newDevice; ok = true
        } else {
            session.addInput(old)
        }
        session.commitConfiguration()
        configureConnections(front: newDevice.position == .front)
        updateRealFlash()
        if ok { installSystemControls(for: newDevice) }
        return ok
    }

    func setManualFocus(_ on: Bool) {
        let lp = lensPosition
        sessionQueue.async { [self] in
            guard var d = device else { return }
            if on, d.isVirtualDevice, !d.isLockingFocusWithCustomLensPositionSupported,
               let physical = physicalDevice(forVirtual: d), switchInput(to: physical) {
                d = physical; swappedForManual = true
                let minFocus = physical.minimumFocusDistance
                let diopters: Float = minFocus > 0 ? 1000 / Float(minFocus) : 10
                DispatchQueue.main.async { self.maxDiopters = diopters }
            } else if !on, swappedForManual, let virtual = camera(.back), switchInput(to: virtual) {
                d = virtual; swappedForManual = false
                publishDeviceInfo(virtual)
            }
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
    /// `display` è lo zoom mostrato (0.5, 1, 3…). Oltre l'ultimo obiettivo fisico lo zoom è digitale (fino a 10×).
    func setZoom(_ display: CGFloat, ramp: Bool = true) {
        sessionQueue.async { [self] in
            // Con la messa a fuoco manuale si usa un solo obiettivo fisico: lo zoom resta fermo
            guard let d = device, d.isVirtualDevice || lensFactors.count <= 1 else { return }
            let mult = max(lensMultiplier, 0.01)
            let upper = min(d.maxAvailableVideoZoomFactor, 10 / mult)
            let target = min(max(display / mult, d.minAvailableVideoZoomFactor), upper)
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
            let shown = ((target * mult) * 100).rounded() / 100
            DispatchQueue.main.async { self.zoom = shown }
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
    private func scheduleMask(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) {
        stateLock.lock()
        if isMasking { stateLock.unlock(); return }
        isMasking = true
        stateLock.unlock()
        maskQueue.async { [self] in
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .fast                         // ~10 ms, adatta al live
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:]).perform([req])
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
        let (rec, requestedFlash, mask) = snapshot()
        // Con un flash fisico la luce vera si accende solo allo scatto: l'anteprima non simula effetti finti
        let flash = requestedFlash && !hasRealFlash()

        // Se la connessione non ha applicato la rotazione verticale (succede dopo il cambio di camera),
        // il frame arriva in orizzontale: lo raddrizziamo noi, con lo specchio per la frontale.
        var source = CIImage(cvPixelBuffer: pb)
        var orientation: CGImagePropertyOrientation = .up
        // (solo in verticale: in orizzontale il frame largo è quello giusto)
        let previewAngle = currentPreviewAngle()
        let expectsPortrait = previewAngle == 90 || previewAngle == 270
        if expectsPortrait && CVPixelBufferGetWidth(pb) > CVPixelBufferGetHeight(pb) {
            // Frontale: verticale e specchiata (selfie). Con .right sarebbe capovolta.
            orientation = (device?.position == .front) ? .leftMirrored : .right
            source = source.oriented(orientation)
            if frameCount % 30 == 0 {
                sessionQueue.async { [self] in
                    configureConnections(front: (device?.position ?? .back) == .front)
                }
            }
        }
        if rec.flash != nil && flash { scheduleMask(pb, orientation: orientation) }

        let out = engine.render(source, mask: mask, recipe: rec, flashOn: flash,
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
                let (rec, requestedFlash, _) = snapshot()
                // Se il flash vero è partito, la foto è già illuminata: niente simulazione sopra
                let simulateFlash = requestedFlash && !photo.resolvedSettings.isFlashEnabled
                let mask = (rec.flash != nil && simulateFlash) ? personMask(for: ci) : nil
                let out = engine.render(ci, mask: mask, recipe: rec, flashOn: simulateFlash,
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
