import AVFoundation
import Vision
import Photos
import CoreImage
import UIKit

enum CameraAuth { case unknown, authorized, denied }

/// Contenitore del solo frame di anteprima: così il mirino si aggiorna a 30 fps
/// senza ridisegnare tutta l'interfaccia.
final class PreviewModel: ObservableObject {
    /// Fotogramma più recente. Non è `@Published`: si scrive nel layer senza far ricalcolare SwiftUI a ogni frame.
    /// Da usare solo sul main thread.
    var image: CGImage? {
        didSet {
            // Niente animazione implicita del layer: il cambio di fotogramma deve essere netto
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
            if image != nil && !hasImage { hasImage = true }
        }
    }
    /// Cambia una sola volta, al primo fotogramma: toglie lo sfondo di riserva.
    @Published private(set) var hasImage = false
    /// Layer della vista del mirino (impostato dalla vista).
    weak var layer: CALayer?
}

/// Testo dei dati di scatto (ƒ/, tempo, ISO) separato dal manager: cambiandolo non si ridisegna tutta l'interfaccia.
final class HUDModel: ObservableObject {
    @Published var text = "ƒ/1.8 · 1/125 · ISO 200"
}

/// Gestisce sessione di cattura, rendering live dei filtri, maschera persona, messa a fuoco manuale e salvataggio.
/// NB: in Xcode 26+ imposta "Default Actor Isolation = nonisolated" (Build Settings) per questo target,
/// oppure Swift Language Mode 5. Il progetto incluso è già configurato così.
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: Stato per la UI
    let preview = PreviewModel()
    let hud = HUDModel()
    @Published var lastPhoto: UIImage?
    @Published var saveCounter = 0
    @Published var recipe: CameraRecipe = CameraRecipe.all[0] { didSet { syncRenderState() } }
    @Published var flashEnabled = true { didSet { syncRenderState() } }
    /// Formato scelto (4:3, 4:5, 9:16, 1:1): vale per tutte le fotocamere tranne l'istantanea, che è sempre quadrata.
    @Published var aspect: FrameAspect = FrameAspect(rawValue: UserDefaults.standard.string(forKey: "frameAspect") ?? "") ?? .classic {
        didSet { UserDefaults.standard.set(aspect.rawValue, forKey: "frameAspect"); syncRenderState() }
    }
    /// Formato effettivo della fotocamera attiva.
    var effectiveAspect: FrameAspect { recipe.cropSquare ? .square : aspect }
    @Published var livePhotoEnabled = UserDefaults.standard.bool(forKey: "livePhotoEnabled") {
        didSet { UserDefaults.standard.set(livePhotoEnabled, forKey: "livePhotoEnabled"); syncRenderState() }
    }
    @Published var livePhotoSupported = false       // l'obiettivo attivo permette le Live Photo
    @Published var manualFocus = false
    @Published var manualFocusSupported = true      // l'obiettivo attivo permette di bloccare il fuoco su una posizione
    @Published var isSwitchingLens = false          // cambio di obiettivo in corso (AF ↔ MF): l'interfaccia vela il mirino
    @Published var isFocusing = false               // l'autofocus sta cercando il fuoco dopo un tocco
    @Published var lensPosition: Float = 0.6        // 0 = vicino ... 1 = infinito
    @Published var maxDiopters: Float = 10          // da minimumFocusDistance
    @Published var zoom: CGFloat = 1
    @Published var zoomFloor: CGFloat = 1
    @Published var zoomCeiling: CGFloat = 25       // zoom massimo mostrato: quello del modello di iPhone, con tetto a 25×
    static let maxDisplayZoom: CGFloat = 25         // zoom massimo dell'app (come l'app Fotocamera sui modelli più recenti)           // zoom minimo raggiungibile ora (cambia con l'obiettivo usato in manuale)
    @Published var supportedMegapixels: [Int] = [12]  // risoluzioni foto della fotocamera posteriore (es. 12, 24, 48)
    @Published var lensStops: [CGFloat] = [1]       // zoom mostrato di ogni obiettivo fisico (es. 0.5, 1, 3)
    @Published var zoomStops: [CGFloat] = [1, 2, 4] // scatti rapidi: obiettivi fisici + tappe digitali
    @Published var exposureBias: Float = 0          // -2...+2 EV
    @Published var authorization: CameraAuth = .unknown
    @Published var isFront = false
    @Published var pendingCount = 0                 // scatti in elaborazione
    @Published var toast: String?

    /// Foto o video retrò. In video l'otturatore avvia e ferma la registrazione.
    enum CaptureMode: String { case photo, video }
    @Published private(set) var captureMode: CaptureMode = .photo
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?

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
    // Protetti da stateLock: scritti sulla sessionQueue, letti anche dal main actor (azioni del Camera Control)
    private var _swappedBase: CGFloat = 1
    private var _swappedForManual = false
    private var _lastLensPosition: Float = 0.6
    private var swappedBase: CGFloat {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _swappedBase }
        set { stateLock.lock(); _swappedBase = newValue; stateLock.unlock() }
    }
    /// zoom mostrato dell'obiettivo fisico usato in manuale (swappedBase); la messa a fuoco manuale usa l'obiettivo fisico invece della virtuale
    private var swappedForManual: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _swappedForManual }
        set { stateLock.lock(); _swappedForManual = newValue; stateLock.unlock() }
    }
    private var lastLensPosition: Float {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastLensPosition }
        set { stateLock.lock(); _lastLensPosition = newValue; stateLock.unlock() }
    }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?   // angolo di scatto secondo la posizione del telefono
    private var rotationDeviceID: String?
    private var inputCache: [String: AVCaptureDeviceInput] = [:]   // input già pronti: creare un input costa decine di ms a ogni cambio
    private var isFlipping = false                  // cambio frontale/posteriore in corso (si ignorano i tocchi ripetuti)
    private var focusObservation: NSKeyValueObservation?   // segue isAdjustingFocus del dispositivo attivo

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
    // Ultimo frame pronto e relativo testo: sul main se ne consegna uno solo alla volta, così i frame non si accumulano
    // Video: comando di avvio/stop (stateLock), registratore (solo videoQueue), microfono (solo sessionQueue)
    private enum RecordCommand { case start, stop }
    private var recordCommand: RecordCommand?
    private var recorder: MovieRecorder?
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var audioReady = false                                // stateLock
    private var videoModeActive = false                           // stateLock: letto dalla sessionQueue
    private var zoomRequest: (display: CGFloat, ramp: Bool)?      // ultima richiesta di zoom non ancora applicata
    private var biasRequest: Float?                               // ultima compensazione dell'esposizione non ancora applicata
    private var pendingFrame: CGImage?
    private var pendingHUD: String?
    private var deliveryScheduled = false
    private var renderLive = false              // Live Photo attiva e supportata
    /// Stato di uno scatto Live Photo (per uniqueID): la foto filtrata e il filmato arrivano in momenti diversi.
    private struct LivePending {
        var jpeg: Data?
        var original: Data?
        var movie: URL?
        var recipe: CameraRecipe?   // fotocamera attiva allo scatto: foto e filmato devono avere lo stesso look
        var awaitingMovie = false   // il filmato è atteso o in elaborazione (filtro applicato ai fotogrammi)
        var ended = false       // lo scatto è terminato: se il filmato non arriva si salva solo la foto
        var failed = false      // scatto fallito: il filmato va scartato
    }
    private var livePending: [Int64: LivePending] = [:]

    private var device: AVCaptureDevice? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _device }
        set { stateLock.lock(); _device = newValue; stateLock.unlock() }
    }

    override init() {
        super.init()
        // Frontale a specchio di default (alzi la destra, si alza la destra): modificabile nelle impostazioni
        UserDefaults.standard.register(defaults: ["mirrorFront": true])
        reloadMirrorFront()
        applyDefaultCamera()
        syncRenderState()
        // LUT di tutte le fotocamere pronte prima del primo uso (in background)
        processQueue.async { [engine] in engine.prewarm(CameraRecipe.all) }
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.resetToContinuous() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func syncRenderState() {
        var rec = recipe
        rec.aspect = effectiveAspect
        stateLock.lock(); renderRecipe = rec; renderFlash = flashEnabled; renderLive = livePhotoEnabled; stateLock.unlock()
    }
    /// Lo scatto Live è ancora in attesa (voce presente)? Funzione sincrona: NSLock non si usa da contesti asincroni.
    private func isLiveCapturePending(_ id: Int64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return livePending[id] != nil
    }
    private func liveRequested() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return renderLive
    }
    private func snapshot() -> (CameraRecipe, Bool, CIImage?) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (renderRecipe, renderFlash, latestMask)
    }

    /// Da chiamare sulla sessionQueue dopo ogni cambio di input.
    private func updateRealFlash() {
        if let d = device { observeInfinity(of: d) }        // dopo ogni cambio di obiettivo: si impara l'infinito del nuovo
        applyVideoFrameRate()                               // e il nuovo obiettivo gira ai fotogrammi del video, se serve
        let ok = photoOutput.supportedFlashModes.contains(.on)
        stateLock.lock(); realFlashAvailable = ok; stateLock.unlock()
        // Live Photo: va abilitata sull'output (se supportata dall'obiettivo attivo)
        let live = photoOutput.isLivePhotoCaptureSupported
        if photoOutput.isLivePhotoCaptureEnabled != live { photoOutput.isLivePhotoCaptureEnabled = live }
        DispatchQueue.main.async { self.livePhotoSupported = live }
    }
    /// L'obiettivo ha un sensore da 24 MP o più: il suo ritaglio 2× resta nitido (qualità ottica).
    private static func hasHighResolutionSensor(_ lens: AVCaptureDevice) -> Bool {
        lens.formats.contains { format in format.supportedMaxPhotoDimensions.contains { megapixels($0) >= 24 } }
    }

    private static func megapixels(_ d: CMVideoDimensions) -> Int {
        Int((Double(d.width) * Double(d.height) / 1_000_000).rounded(.down))     // 4032×3024 → 12, 8064×6048 → 48
    }

    /// Risoluzione massima delle foto per il dispositivo attivo: la più grande che il sensore offre senza superare
    /// quella scelta. Da chiamare sulla sessionQueue, tra beginConfiguration e commitConfiguration (dopo ogni cambio
    /// di input): cambiarla a sessione avviata ricostruisce la pipeline e ferma il mirino.
    private func applyPhotoResolution() {
        guard let d = device else { return }
        let dims = d.activeFormat.supportedMaxPhotoDimensions.sorted { Self.megapixels($0) < Self.megapixels($1) }
        guard let smallest = dims.first else { return }
        let wanted = DeviceProfile.photoMegapixels
        let chosen = dims.last { Self.megapixels($0) <= wanted } ?? smallest
        let current = photoOutput.maxPhotoDimensions
        if current.width != chosen.width || current.height != chosen.height { photoOutput.maxPhotoDimensions = chosen }
        // Le opzioni da mostrare vengono dalla posteriore (la frontale ha quasi sempre solo 12 MP)
        if d.position == .back {
            let options = Array(Set(dims.map(Self.megapixels))).sorted()
            DispatchQueue.main.async { self.supportedMegapixels = options }
        }
    }

    /// Da chiamare quando cambia l'impostazione della risoluzione.
    func refreshPhotoResolution() {
        sessionQueue.async { [self] in
            guard configured else { return }
            session.beginConfiguration()
            applyPhotoResolution()
            session.commitConfiguration()
        }
    }

    private func hasRealFlash() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return realFlashAvailable
    }

    private func setAuth(_ a: CameraAuth) {
        DispatchQueue.main.async { self.authorization = a }
    }

    // MARK: Avvio / stop
    /// Fotocamera principale scelta in Impostazioni di iOS (Settings.bundle). Si applica all'avvio e ogni volta
    /// che la scelta cambia, così non sovrascrive la fotocamera scelta nell'app a ogni ritorno in primo piano.
    private var appliedDefaultCamera: String?      // solo in memoria: a ogni avvio a freddo la scelta si riapplica
    private func applyDefaultCamera() {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: "defaultCamera"),
              id != appliedDefaultCamera else { return }
        appliedDefaultCamera = id
        if let r = CameraRecipe.all.first(where: { $0.id == id }) { recipe = r }
    }

    /// Chiede subito, al primo avvio, il permesso di salvare nella libreria Foto (solo aggiunta), invece di aspettare il primo scatto.
    private func requestPhotoAccessIfNeeded() {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    func start() {
        reloadMirrorFront()         // può essere cambiata dalle Impostazioni di iOS mentre l'app era in secondo piano
        DispatchQueue.main.async { self.applyDefaultCamera() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setAuth(.authorized); configureAndRun(); requestPhotoAccessIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                self.setAuth(ok ? .authorized : .denied)
                if ok { self.configureAndRun() }
                self.requestPhotoAccessIfNeeded()       // dopo la fotocamera: un permesso alla volta
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
        z == z.rounded() ? "\(Int(z))×" : "\(Double(z).formatted(.number.precision(.fractionLength(1))))×"      // separatore decimale secondo la lingua del sistema
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

    /// Impostazione "Specchia la frontale" (Impostazioni dell'app): vale per mirino e foto, solo sulla frontale.
    /// Copia in memoria dell'impostazione: serve a ogni fotogramma (30 volte al secondo) e leggere `UserDefaults` ogni volta costa.
    private var _mirrorFront = true
    private var mirrorFront: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _mirrorFront }
    private func reloadMirrorFront() {
        let value = UserDefaults.standard.bool(forKey: "mirrorFront")
        stateLock.lock(); _mirrorFront = value; stateLock.unlock()
    }

    /// Da chiamare quando l'impostazione cambia.
    func refreshMirroring() {
        reloadMirrorFront()
        sessionQueue.async { [self] in
            configureConnections(front: (device?.position ?? .back) == .front)
        }
    }

    private func configureConnections(front: Bool) {
        // Le connessioni non specchiano mai: lo specchio della frontale lo applichiamo noi sull'immagine (vedi `mirrorFront`),
        // così il risultato non dipende dal comportamento dell'hardware.
        let mirrored = false
        if let c = videoOutput.connection(with: .video) {
            let angle = currentPreviewAngle()
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = mirrored }
        }
        if let c = photoOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = mirrored }
        }
    }

    private func publishDeviceInfo(_ dev: AVCaptureDevice) {
        // Il fuoco manuale richiede una lente con autofocus: le frontali più vecchie sono a fuoco fisso
        let canLock = dev.isLockingFocusWithCustomLensPositionSupported
            || (dev.isVirtualDevice && dev.constituentDevices.contains { $0.isLockingFocusWithCustomLensPositionSupported })
        DispatchQueue.main.async { self.manualFocusSupported = canLock }
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
        // Scatti rapidi, come nell'app Fotocamera: gli obiettivi veri, più il ritaglio 2× degli obiettivi con sensore
        // ad alta risoluzione (48 MP), che ha qualità ottica. Niente tappe solo digitali (il vecchio 4× fisso):
        // sull'iPhone 17 diventa 0,5 · 1 · 2, sui Pro con tele da 48 MP 0,5 · 1 · 2 · 4 · 8, sui sensori da 12 MP
        // restano solo gli obiettivi. Per gli altri ingrandimenti c'è il pizzico.
        let ceiling = max(1, min(dev.maxAvailableVideoZoomFactor * mult, Self.maxDisplayZoom))       // massimo di questo modello, nel valore mostrato, tetto 25×
        let lenses = dev.isVirtualDevice ? dev.constituentDevices : [dev]
        var quick = stops
        if lenses.count == stops.count {
            for (stop, lens) in zip(stops, lenses) where Self.hasHighResolutionSensor(lens) {
                let crop = ((stop * 2) * 10).rounded() / 10
                if crop <= ceiling, !quick.contains(where: { abs($0 - crop) < 0.3 }) { quick.append(crop) }
            }
        }
        quick.sort()
        DispatchQueue.main.async {
            self.lensStops = stops; self.zoomStops = quick; self.zoom = 1
            self.zoomFloor = stops.first ?? 1; self.zoomCeiling = ceiling
        }
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
            // Senza questo il massimo è .speed: niente Deep Fusion / riduzione del rumore nelle foto
            photoOutput.maxPhotoQualityPrioritization = .balanced
            configureConnections(front: false)
            applyPhotoResolution()
            session.commitConfiguration()
            configured = true
            updateRealFlash()

            publishDeviceInfo(dev)
            installSystemControls(for: dev)
            session.startRunning()
            prewarmOtherCamera()
        }
    }

    // MARK: Camera Control (iPhone 16 e successivi)
    /// Controlli sul tasto Camera Control. Da chiamare sulla sessionQueue (e di nuovo quando cambia AF/MF).
    /// - Automatico: zoom ed esposizione.
    /// - Manuale: il tasto sposta la messa a fuoco (primo controllo), poi zoom.
    /// Lo scatto con la pressione del tasto è gestito in ContentView (onCameraCaptureEvent).
    private func installSystemControls(for dev: AVCaptureDevice) {
        guard #available(iOS 18.0, *), session.supportsControls else { return }
        for control in session.controls { session.removeControl(control) }
        session.setControlsDelegate(self, queue: sessionQueue)

        stateLock.lock(); let manual = manualActive; stateLock.unlock()

        // Zoom continuo del sistema: attraversa gli obiettivi fisici e prosegue in digitale.
        // Le action girano sul main actor e tengono allineata l'interfaccia.
        let zoomSlider = AVCaptureSystemZoomSlider(device: dev) { [weak self] factor in
            guard let self else { return }
            // In manuale si usa un solo obiettivo fisico: il suo zoom di base non è quello della virtuale
            let base = self.swappedForManual ? self.swappedBase : self.lensMultiplier
            self.zoom = ((factor * base) * 100).rounded() / 100
        }

        var controls: [AVCaptureControl]
        if manual {
            // Messa a fuoco: scorre da vicino (0) a infinito (1), come la ghiera a schermo
            let focusSlider = AVCaptureSlider(String(localized: "Messa a fuoco"), symbolName: "scope", in: 0...1)
            focusSlider.value = lastLensPosition
            focusSlider.setActionQueue(sessionQueue) { [weak self] value in
                self?.focusFromCameraControl(value)
            }
            controls = [focusSlider, zoomSlider]
        } else {
            let biasSlider = AVCaptureSystemExposureBiasSlider(device: dev) { [weak self] bias in
                self?.exposureBias = bias
            }
            controls = [zoomSlider, biasSlider]
        }
        for control in controls where session.canAddControl(control) {
            session.addControl(control)
        }
    }

    // MARK: Fotocamera frontale / posteriore
    /// Input già creato per il dispositivo (da sessionQueue). Il primo uso lo crea, i successivi sono immediati.
    private func cachedInput(for dev: AVCaptureDevice) -> AVCaptureDeviceInput? {
        if let input = inputCache[dev.uniqueID] { return input }
        guard let input = try? AVCaptureDeviceInput(device: dev) else { return nil }
        inputCache[dev.uniqueID] = input
        return input
    }

    /// Prepara in anticipo l'input dell'altra fotocamera, così il primo cambio non deve crearlo.
    private func prewarmOtherCamera() {
        sessionQueue.async { [self] in
            guard let other = camera((device?.position ?? .back) == .back ? .front : .back) else { return }
            _ = cachedInput(for: other)
        }
    }

    func flipCamera() {
        // L'interfaccia reagisce subito (mirino velato, come nell'app Fotocamera), prima ancora che la sessione cambi
        DispatchQueue.main.async { self.isSwitchingLens = true }
        sessionQueue.async { [self] in
            guard configured, let oldInput = currentInput, !isFlipping else {
                DispatchQueue.main.async { self.isSwitchingLens = false }
                return
            }
            isFlipping = true
            defer {
                isFlipping = false
                // Qualche fotogramma della nuova fotocamera prima di togliere il velo
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.isSwitchingLens = false }
            }
            let toFront = (device?.position ?? .back) == .back
            guard let dev = camera(toFront ? .front : .back),
                  let input = cachedInput(for: dev) else { return }

            session.beginConfiguration()
            session.removeInput(oldInput)
            var switched = false
            if session.canAddInput(input) {
                session.addInput(input); currentInput = input; device = dev; switched = true
            } else {
                session.addInput(oldInput)
            }
            applyPhotoResolution()          // ogni fotocamera ha le sue risoluzioni
            session.commitConfiguration()
            // Dopo il commit: le connessioni del nuovo input esistono e accettano la rotazione verticale
            configureConnections(front: (device?.position ?? .back) == .front)
            updateRealFlash()
            guard switched else { return }

            stateLock.lock(); latestMask = nil; manualActive = false; stateLock.unlock()
            swappedForManual = false
            // Prima l'interfaccia (appena la nuova fotocamera è attiva), poi i dati del dispositivo
            DispatchQueue.main.async {
                self.isFront = toFront
                self.zoom = 1
                self.manualFocus = false
                self.exposureBias = 0
            }
            publishDeviceInfo(dev)
            installSystemControls(for: dev)        // i cursori del Camera Control devono seguire la nuova fotocamera
            prewarmOtherCamera()
        }
    }

    // MARK: Scatto
    func capturePhoto() {
        // Troppi scatti ancora in elaborazione: si aspetta, invece di riempire la memoria e farsi chiudere dal sistema
        if pendingCount >= DeviceProfile.maxPendingCaptures {
            toast = String(localized: "Sto ancora elaborando gli scatti precedenti.")
            return
        }
        DispatchQueue.main.async { self.pendingCount += 1 }
        sessionQueue.async { [self] in
            guard session.isRunning else { finishOne(toast: String(localized: "Fotocamera non disponibile.")); return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced     // più dettaglio e meno rumore, senza ritardo evidente
            // Flash acceso su una fotocamera che lo prevede: si accende la luce vera (LED o schermo sulla frontale)
            let (rec, flash, _) = snapshot()
            if flash, rec.flash != nil, photoOutput.supportedFlashModes.contains(.on) {
                settings.flashMode = .on
            }
            // Live Photo: il filmato abbinato viene scritto in un file temporaneo e salvato a fine scatto
            if liveRequested(), photoOutput.isLivePhotoCaptureEnabled {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).mov")
                updateLive(settings.uniqueID, register: true) { $0.awaitingMovie = true; $0.recipe = rec }      // registra lo scatto come Live Photo in attesa
            }
            // Alta risoluzione (24/48 MP) solo per le foto normali: con il filmato della Live Photo si resta al formato
            // standard, che è quello predefinito di ogni scatto
            let maxDims = photoOutput.maxPhotoDimensions
            if settings.livePhotoMovieFileURL == nil, maxDims.width > 0, maxDims.height > 0 {
                settings.maxPhotoDimensions = maxDims
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
        let index = lensIndex(for: v)
        return devices.indices.contains(index) ? devices[index] : devices.first
    }

    private func lensIndex(for v: AVCaptureDevice) -> Int {
        var index = 0
        for (i, f) in lensFactors.enumerated() where f <= v.videoZoomFactor + 0.01 { index = i }
        return index
    }

    /// Da chiamare sulla sessionQueue.
    private func switchInput(to newDevice: AVCaptureDevice) -> Bool {
        guard let old = currentInput, let input = cachedInput(for: newDevice) else { return false }
        session.beginConfiguration()
        session.removeInput(old)
        var ok = false
        if session.canAddInput(input) {
            session.addInput(input); currentInput = input; device = newDevice; ok = true
        } else {
            session.addInput(old)
        }
        applyPhotoResolution()
        session.commitConfiguration()
        configureConnections(front: newDevice.position == .front)
        updateRealFlash()
        if ok { installSystemControls(for: newDevice) }
        return ok
    }

    /// Sull'iPhone la posizione 1.0 della lente va oltre l'infinito reale e l'orizzonte risulta sfocato.
    /// La ghiera (0...1) viene quindi mappata su 0...(posizione dell'infinito di quell'obiettivo).
    /// Quella posizione cambia da modello a modello e da obiettivo a obiettivo: il valore di partenza è una stima,
    /// poi l'app lo impara dall'autofocus del dispositivo (vedi `learnInfinity`) e lo ricorda per ogni obiettivo.
    private let infinityDefault: Float = 0.85
    private var infinityObservation: NSKeyValueObservation?        // solo da sessionQueue
    private var _infinityLearned: [String: Float] = [:]            // protetto da stateLock

    private func infinityKey(_ d: AVCaptureDevice) -> String { "infinityLens.\(d.uniqueID)" }

    /// Posizione dell'infinito dell'obiettivo attivo: quella appresa, o la stima di partenza.
    private func infinityPosition() -> Float {
        guard let d = device else { return infinityDefault }
        let key = infinityKey(d)
        stateLock.lock()
        if let known = _infinityLearned[key] { stateLock.unlock(); return known }
        stateLock.unlock()
        let stored = UserDefaults.standard.float(forKey: key)       // 0 se non c'è
        let value = stored > infinityDefault ? min(stored, 1) : infinityDefault
        stateLock.lock(); _infinityLearned[key] = value; stateLock.unlock()
        return value
    }

    private func deviceLensPosition(_ ring: Float) -> Float {
        min(1, max(0, ring)) * infinityPosition()
    }

    /// Da chiamare sulla sessionQueue dopo ogni cambio di obiettivo: segue i momenti in cui l'autofocus si ferma.
    private func observeInfinity(of d: AVCaptureDevice) {
        infinityObservation = d.observe(\.isAdjustingFocus, options: [.new]) { [weak self] dev, change in
            if change.newValue == false { self?.learnInfinity(dev) }
        }
    }

    /// Quando l'autofocus si ferma più lontano di quanto la ghiera arrivava, l'infinito di quell'obiettivo è oltre:
    /// si alza il limite (e si ricorda), così il giro completo della ghiera arriva davvero all'infinito.
    /// Non si abbassa mai da solo: un autofocus fermo vicino non dice nulla sull'infinito.
    private func learnInfinity(_ d: AVCaptureDevice) {
        guard d.focusMode != .locked else { return }               // in manuale la posizione l'abbiamo scelta noi
        let position = d.lensPosition
        guard position > 0, position <= 1 else { return }
        let key = infinityKey(d)
        stateLock.lock()
        let known = _infinityLearned[key] ?? max(UserDefaults.standard.float(forKey: key), infinityDefault)
        guard position > known + 0.005 else { stateLock.unlock(); return }
        _infinityLearned[key] = position
        stateLock.unlock()
        UserDefaults.standard.set(position, forKey: key)
    }

    /// Cursore "Messa a fuoco" del Camera Control (gira sulla sessionQueue, disponibile in manuale):
    /// sposta la lente e tiene allineata la ghiera a schermo.
    @available(iOS 18.0, *)
    private func focusFromCameraControl(_ value: Float) {
        let v = min(1, max(0, value))
        lastLensPosition = v
        DispatchQueue.main.async { self.lensPosition = v }
        applyLensPosition(v)
    }

    /// `completion` (sul main) riceve l'esito: l'interfaccia passa subito a MF in modo ottimistico e si corregge se non riesce.
    func setManualFocus(_ on: Bool, lensPosition requested: Float? = nil, completion: ((Bool) -> Void)? = nil) {
        let lp = requested ?? lensPosition
        lastLensPosition = lp
        sessionQueue.async { [self] in
            guard var d = device else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            // Il cambio dell'obiettivo ferma il mirino per un istante: lo si copre con una sfocatura dolce (vedi ContentView)
            let willSwap = (on && d.isVirtualDevice && !d.isLockingFocusWithCustomLensPositionSupported) || (!on && swappedForManual)
            if willSwap { DispatchQueue.main.async { self.isSwitchingLens = true } }
            if on, d.isVirtualDevice, !d.isLockingFocusWithCustomLensPositionSupported,
               case let shownZoom = d.videoZoomFactor * lensMultiplier,
               case let index = lensIndex(for: d),
               let physical = physicalDevice(forVirtual: d), switchInput(to: physical) {
                d = physical
                // Sull'obiettivo fisico lo zoom 1.0 corrisponde allo zoom mostrato di quell'obiettivo: si mantiene lo zoom attuale
                let base = max(lensFactors[min(index, lensFactors.count - 1)] * lensMultiplier, 0.01)
                swappedBase = base; swappedForManual = true
                let ceiling = max(1, min(physical.maxAvailableVideoZoomFactor * base, Self.maxDisplayZoom))     // massimo di questo obiettivo, tetto 25×
                DispatchQueue.main.async { self.zoomFloor = base; self.zoomCeiling = ceiling }
                if (try? physical.lockForConfiguration()) != nil {
                    let upper = min(physical.maxAvailableVideoZoomFactor, Self.maxDisplayZoom / base)
                    let target = min(max(shownZoom / base, physical.minAvailableVideoZoomFactor), upper)
                    physical.videoZoomFactor = target
                    physical.unlockForConfiguration()
                    let shown = ((target * base) * 100).rounded() / 100
                    DispatchQueue.main.async { self.zoom = shown }
                }
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
                        // Posizione più recente: la ghiera può essersi mossa mentre l'obiettivo veniva cambiato
                        d.setFocusModeLocked(lensPosition: deviceLensPosition(lastLensPosition))
                        applied = true
                    }
                } else if d.isFocusModeSupported(.continuousAutoFocus) {
                    d.focusMode = .continuousAutoFocus
                }
            } catch { }
            let result = on && applied
            stateLock.lock(); manualActive = result; stateLock.unlock()
            installSystemControls(for: d)       // il Camera Control passa da zoom/esposizione a fuoco (o viceversa)
            DispatchQueue.main.async { self.manualFocus = result; completion?(result) }
            if willSwap {
                // Qualche fotogramma del nuovo obiettivo prima di togliere il velo
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.isSwitchingLens = false }
            }
        }
    }

    /// Applica al device la posizione della ghiera (il binding aggiorna già `lensPosition`).
    func applyLensPosition(_ p: Float) {
        lastLensPosition = min(1, max(0, p))
        sessionQueue.async { [self] in
            guard let d = device, d.isLockingFocusWithCustomLensPositionSupported else { return }
            do {
                try d.lockForConfiguration()
                defer { d.unlockForConfiguration() }
                d.setFocusModeLocked(lensPosition: deviceLensPosition(p))
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
                // Con lo zoom digitale l'immagine mostrata è un ritaglio centrale del sensore: il punto va riportato
                // alle coordinate del sensore intero, altrimenti si mette a fuoco troppo lontano dal tocco
                var crop = d.videoZoomFactor
                if d.isVirtualDevice, !swappedForManual { crop /= max(lensFactors[lensIndex(for: d)], 0.01) }
                crop = max(crop, 1)
                let target = CGPoint(x: min(max(0.5 + (p.x - 0.5) / crop, 0), 1), y: min(max(0.5 + (p.y - 0.5) / crop, 0), 1))

                if d.isFocusPointOfInterestSupported {
                    if d.isAutoFocusRangeRestrictionSupported { d.autoFocusRangeRestriction = .none }    // vicino e lontano
                    if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = true }                  // la lente si sposta senza scatti
                    d.focusPointOfInterest = target
                    d.focusMode = .autoFocus
                    // Stato della ricerca del fuoco: l'interfaccia mostra "sto cercando" e poi "fuoco bloccato"
                    focusObservation = d.observe(\.isAdjustingFocus, options: [.new]) { [weak self] device, change in
                        let adjusting = change.newValue ?? device.isAdjustingFocus
                        DispatchQueue.main.async { self?.isFocusing = adjusting }
                    }
                }
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = target; d.exposureMode = .continuousAutoExposure }
                // L'autofocus automatico NON deve riprendere il comando e riportare il fuoco al centro quando la scena cambia:
                // il fuoco resta esattamente dove hai toccato, finché non tocchi un altro punto o torni all'automatico (tasto AF).
                d.isSubjectAreaChangeMonitoringEnabled = false
            } catch { }
        }
    }

    /// Torna all'autofocus continuo al centro (tocco sul segmento AF quando è già selezionato).
    func resumeAutoFocus() { resetToContinuous() }

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
        // Col pizzico arrivano decine di richieste al secondo: ogni scrittura sulla fotocamera costa (blocco di configurazione),
        // quindi se una è già in attesa la si sostituisce con quella più recente invece di accodarne altre.
        stateLock.lock()
        let alreadyQueued = zoomRequest != nil
        zoomRequest = (display, ramp)
        stateLock.unlock()
        guard !alreadyQueued else { return }
        sessionQueue.async { [self] in
            stateLock.lock(); let request = zoomRequest; zoomRequest = nil; stateLock.unlock()
            guard let request, let d = device else { return }
            let display = request.display, ramp = request.ramp
            // Con la messa a fuoco manuale si usa un solo obiettivo fisico: lo zoom è digitale su quell'obiettivo
            let mult = swappedForManual ? swappedBase : max(lensMultiplier, 0.01)
            let upper = min(d.maxAvailableVideoZoomFactor, Self.maxDisplayZoom / mult)       // limite del modello di iPhone, con tetto 25×
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
            DispatchQueue.main.async { if abs(self.zoom - shown) > 0.004 { self.zoom = shown } }
        }
    }

    func setExposureBias(_ value: Float) {
        let clamped = min(2, max(-2, value))
        DispatchQueue.main.async { self.exposureBias = clamped }      // il cursore segue subito il dito
        // La scrittura sulla fotocamera invece si unisce: conta solo il valore più recente
        stateLock.lock()
        let alreadyQueued = biasRequest != nil
        biasRequest = clamped
        stateLock.unlock()
        guard !alreadyQueued else { return }
        sessionQueue.async { [self] in
            stateLock.lock(); let latest = biasRequest; biasRequest = nil; stateLock.unlock()
            guard let latest, let d = device else { return }
            let b = min(d.maxExposureTargetBias, max(d.minExposureTargetBias, latest))
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
    /// Aggiorna lo stato di una Live Photo e, appena la foto filtrata e il filmato sono pronti (o lo scatto è finito
    /// senza filmato), la salva. Chiamabile da qualunque coda.
    private func updateLive(_ id: Int64, register: Bool = false, _ change: (inout LivePending) -> Void) {
        stateLock.lock()
        // Callback tardive di scatti già chiusi non devono ricreare voci che nessuno cancellerebbe
        guard register || livePending[id] != nil else { stateLock.unlock(); return }
        var p = livePending[id] ?? LivePending()
        change(&p)
        var ready: LivePending?
        if p.failed {
            // Il filmato (anche se arriva dopo) non servirà: si scarta. La voce sparisce a fine scatto.
            livePending[id] = p.ended ? nil : p
            if let movie = p.movie { try? FileManager.default.removeItem(at: movie); p.movie = nil; livePending[id]?.movie = nil }
        } else if p.jpeg != nil, p.movie != nil || (p.ended && !p.awaitingMovie) {
            livePending[id] = nil
            ready = p
        } else {
            livePending[id] = p
        }
        stateLock.unlock()
        if let ready, let jpeg = ready.jpeg { save(jpeg, original: ready.original, liveMovie: ready.movie) }
    }

    /// Identificatore che abbina foto e filmato di una Live Photo (MakerNote Apple, chiave 17).
    private func livePhotoIdentifier(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        return maker["17"] as? String
    }

    /// Come sopra, dai metadati già decodificati di AVCapturePhoto.
    private func livePhotoIdentifier(in metadata: [String: Any]) -> String? {
        let maker = metadata[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        return maker?["17"] as? String
    }

    private func save(_ jpeg: Data, original: Data?, liveMovie: URL? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
            guard status == .authorized || status == .limited else {
                if let liveMovie { try? FileManager.default.removeItem(at: liveMovie) }
                finishOne(toast: String(localized: "Consenti l'accesso alle Foto in Impostazioni per salvare gli scatti."))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                // L'originale viene aggiunto per primo: lo scatto filtrato resta il più recente in libreria
                if let original {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: original, options: nil)
                }
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: jpeg, options: nil)
                // Live Photo: il filmato si abbina alla foto filtrata tramite lo stesso identificatore
                if let liveMovie {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: liveMovie, options: options)
                }
            }) { ok, _ in
                if !ok, let liveMovie { try? FileManager.default.removeItem(at: liveMovie) }
                guard ok else { self.finishOne(toast: String(localized: "Salvataggio non riuscito.")); return }
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
        // L'audio arriva sulla stessa coda dei fotogrammi: va solo nel filmato in registrazione
        if output === audioOutput { recorder?.appendAudio(sampleBuffer); return }
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
            // Il sensore della frontale è montato a 180° rispetto alla posteriore: con .right la frontale esce capovolta
            orientation = (device?.position == .front) ? .left : .right
            source = source.oriented(orientation)
            if frameCount % 30 == 0 {
                sessionQueue.async { [self] in
                    configureConnections(front: (device?.position ?? .back) == .front)
                }
            }
        }
        // In orizzontale (soprattutto con la frontale) la rotazione può restare quella verticale: il frame arriva in piedi.
        // Lo raddrizziamo noi, con lo specchio per la frontale, e la connessione viene riallineata.
        if !expectsPortrait && CVPixelBufferGetHeight(pb) > CVPixelBufferGetWidth(pb) {
            let front = device?.position == .front       // frontale: stesso discorso, verso opposto alla posteriore
            orientation = (previewAngle == 0) != front ? .left : .right
            source = source.oriented(orientation)
            if frameCount % 30 == 0 {
                sessionQueue.async { [self] in
                    configureConnections(front: (device?.position ?? .back) == .front)
                }
            }
        }
        // Frontale a specchio (alzi la destra, si alza la destra): capovolgimento orizzontale dell'immagine e della maschera
        let mirrored = device?.position == .front && mirrorFront
        if mirrored { source = source.oriented(.upMirrored) }
        let personMatte = mirrored ? mask?.oriented(.upMirrored) : mask
        // La rotazione della connessione non coincide con quella voluta: riapplicala
        if frameCount % 15 == 0, abs(connection.videoRotationAngle - previewAngle) > 0.5 {
            sessionQueue.async { [self] in
                configureConnections(front: (device?.position ?? .back) == .front)
            }
        }
        if rec.flash != nil && flash { scheduleMask(pb, orientation: orientation) }

        // Registrazione: si filtra una volta sola in 720p, e lo stesso fotogramma va nel filmato e nel mirino
        let command = takeRecordCommand()
        if command == .stop { finishRecording() }
        let recording = command == .start || recorder != nil
        let out = engine.render(source, mask: personMatte, recipe: rec, flashOn: flash,
                                time: CACurrentMediaTime(), quality: recording ? .video : .preview)
        if command == .start, recorder == nil { beginRecording(size: out.extent.size) }
        recorder?.appendVideo(out, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                              context: engine.context, colorSpace: engine.outputColorSpace)
        guard let cg = engine.context.createCGImage(out, from: out.extent) else { return }

        frameCount += 1
        var hud: String?
        if frameCount % 15 == 0, let d = device {
            let dur = max(d.exposureDuration.seconds, 0.0001)
            hud = String(format: "ƒ/%.1f · 1/%ld · ISO %ld", d.lensAperture, Int((1 / dur).rounded()), Int(d.iso))
        }
        // Se il main non ha ancora consegnato il frame precedente, lo si sostituisce con questo (più recente)
        stateLock.lock()
        pendingFrame = cg
        if let hud { pendingHUD = hud }
        let needsDelivery = !deliveryScheduled
        deliveryScheduled = true
        stateLock.unlock()
        guard needsDelivery else { return }
        DispatchQueue.main.async { [self] in
            stateLock.lock()
            let frame = pendingFrame, text = pendingHUD
            pendingFrame = nil; pendingHUD = nil; deliveryScheduled = false
            stateLock.unlock()
            if let frame { preview.image = frame }
            if let text, text != self.hud.text { self.hud.text = text }
        }
    }
}

// L'audio del microfono usa lo stesso metodo dei fotogrammi (vedi sopra)
extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {}

// MARK: - Video retrò
extension CameraManager {
    /// Passa da foto a video (o viceversa). Il microfono si collega solo in video: in foto non compare l'indicatore
    /// arancione del microfono e le Live Photo restano come prima.
    func setCaptureMode(_ mode: CaptureMode) {
        guard !isRecording, mode != captureMode else { return }
        captureMode = mode
        stateLock.lock(); videoModeActive = mode == .video; stateLock.unlock()
        refreshVideoSettings()
    }

    /// Applica le impostazioni del video (fotogrammi al secondo, audio). Da chiamare quando cambiano;
    /// non durante una registrazione, che resta con le impostazioni con cui è partita.
    func refreshVideoSettings() {
        guard !isRecording else { return }
        sessionQueue.async { [self] in applyVideoFrameRate() }
        guard captureMode == .video, VideoSettings.recordsAudio else {
            sessionQueue.async { [self] in detachAudio() }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [self] granted in
            if granted {
                sessionQueue.async { [self] in attachAudio() }
            } else {
                DispatchQueue.main.async {
                    self.toast = String(localized: "Senza il microfono i video saranno muti. Puoi attivarlo nelle Impostazioni.")
                }
            }
        }
    }

    func startRecording() {
        guard captureMode == .video, !isRecording, authorization == .authorized else { return }
        stateLock.lock(); recordCommand = .start; stateLock.unlock()
        isRecording = true
        recordingStart = Date()
    }

    func stopRecording() {
        guard isRecording else { return }
        stateLock.lock(); recordCommand = .stop; stateLock.unlock()
        isRecording = false
        recordingStart = nil
        pendingCount += 1                               // la miniatura mostra l'elaborazione finché il video non è salvato
        // Se la sessione si ferma (app in secondo piano) non arrivano altri fotogrammi: il filmato si chiude comunque
        videoQueue.async { [self] in finishRecordingIfRequested() }
    }

    private func takeRecordCommand() -> RecordCommand? {
        stateLock.lock(); defer { stateLock.unlock() }
        let command = recordCommand
        recordCommand = nil
        return command
    }

    /// Solo videoQueue. Chiude il filmato se è stato chiesto lo stop (senza consumare un eventuale avvio).
    private func finishRecordingIfRequested() {
        stateLock.lock()
        let stop = recordCommand == .stop
        if stop { recordCommand = nil }
        stateLock.unlock()
        if stop { finishRecording() }
    }

    /// Solo videoQueue. La dimensione del filmato è quella del primo fotogramma filtrato (lati pari).
    private func beginRecording(size: CGSize) {
        let w = max(2, Int(size.width.rounded()) / 2 * 2), h = max(2, Int(size.height.rounded()) / 2 * 2)
        stateLock.lock(); let audio = audioReady; stateLock.unlock()
        recorder = MovieRecorder(size: CGSize(width: w, height: h), audio: audio)
        if recorder == nil {
            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingStart = nil
                self.toast = String(localized: "Registrazione non riuscita.")
            }
        }
    }

    /// Solo videoQueue.
    private func finishRecording() {
        guard let r = recorder else { finishOne(); return }
        recorder = nil
        r.finish { [weak self] url in
            guard let self else { return }
            guard let url else { self.finishOne(toast: String(localized: "Registrazione non riuscita.")); return }
            self.saveVideo(url)
        }
    }

    /// Solo sessionQueue. In video la fotocamera gira ai fotogrammi scelti (24 o 30 al secondo); in foto torna
    /// al comportamento predefinito, che allunga l'esposizione al buio.
    private func applyVideoFrameRate() {
        guard let d = device else { return }
        stateLock.lock(); let video = videoModeActive; stateLock.unlock()
        do {
            try d.lockForConfiguration()
            defer { d.unlockForConfiguration() }
            if video {
                let fps = Double(VideoSettings.frameRate)
                guard d.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate })
                else { return }
                let duration = CMTime(value: 1, timescale: CMTimeScale(VideoSettings.frameRate))
                d.activeVideoMinFrameDuration = duration
                d.activeVideoMaxFrameDuration = duration
            } else {
                d.activeVideoMinFrameDuration = .invalid       // .invalid = valori predefiniti del formato
                d.activeVideoMaxFrameDuration = .invalid
            }
        } catch { }
    }

    /// Solo sessionQueue.
    private func attachAudio() {
        guard audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input); audioInput = input }
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(audioOutput)
        }
        session.commitConfiguration()
        stateLock.lock(); audioReady = audioInput != nil; stateLock.unlock()
    }

    /// Solo sessionQueue.
    private func detachAudio() {
        stateLock.lock(); audioReady = false; stateLock.unlock()
        guard let input = audioInput else { return }
        session.beginConfiguration()
        session.removeInput(input)
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        session.commitConfiguration()
        audioInput = nil
    }

    private func saveVideo(_ url: URL) {
        Task { [self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            let thumb = (try? await generator.image(at: .zero).image).map { UIImage(cgImage: $0) }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
                guard status == .authorized || status == .limited else {
                    try? FileManager.default.removeItem(at: url)
                    finishOne(toast: String(localized: "Consenti l'accesso alle Foto in Impostazioni per salvare gli scatti."))
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
                }) { ok, _ in
                    guard ok else {
                        try? FileManager.default.removeItem(at: url)
                        self.finishOne(toast: String(localized: "Salvataggio non riuscito."))
                        return
                    }
                    DispatchQueue.main.async {
                        self.lastPhoto = thumb
                        self.saveCounter += 1
                        self.pendingCount = max(0, self.pendingCount - 1)
                    }
                }
            }
        }
    }
}

// MARK: - Foto finale
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        guard error == nil, let data = photo.fileDataRepresentation() else {
            updateLive(id) { $0.failed = true }
            finishOne(toast: String(localized: "Scatto non riuscito. Riprova."))
            return
        }
        // Live Photo: la foto filtrata riceve lo stesso identificatore dell'originale, così il filmato si abbina a lei
        // (si usa lo stato registrato allo scatto: le dimensioni del filmato nei resolvedSettings non sono affidabili)
        stateLock.lock(); let isLive = livePending[id] != nil; stateLock.unlock()
        let liveID = isLive ? (livePhotoIdentifier(in: data) ?? livePhotoIdentifier(in: photo.metadata)) : nil
        if isLive && liveID == nil {                                            // senza identificatore: foto normale
            updateLive(id) { $0.failed = true }
            DispatchQueue.main.async { self.toast = String(localized: "Live Photo non abbinabile: foto salvata senza movimento.") }
        }
        let keepOriginal = UserDefaults.standard.bool(forKey: "saveOriginal")

        // Frontale a specchio: la foto filtrata viene capovolta in orizzontale, come il mirino
        let mirrorShot = device?.position == .front && mirrorFront

        // Una sola elaborazione alla volta: i 12 MP filtrati sono pesanti in memoria
        processQueue.async { [self] in
            autoreleasepool {
                guard var ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                    finishOne(toast: String(localized: "Impossibile elaborare la foto."))
                    return
                }
                if mirrorShot { ci = ci.oriented(.upMirrored) }
                let (rec, requestedFlash, _) = snapshot()
                // Se il flash vero è partito, la foto è già illuminata: niente simulazione sopra
                let simulateFlash = requestedFlash && !photo.resolvedSettings.isFlashEnabled
                let mask = (rec.flash != nil && simulateFlash) ? personMask(for: ci) : nil
                let out = engine.render(ci, mask: mask, recipe: rec, flashOn: simulateFlash,
                                        time: CACurrentMediaTime(), quality: .photo)
                // Display P3: stesso spazio del filtro e delle foto dell'iPhone (niente taglio dei colori saturi)
                let sRGB = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)!
                let jpeg: Data?
                if let liveID {
                    jpeg = liveJPEG(of: out, identifier: liveID, colorSpace: sRGB)
                } else {
                    let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                    jpeg = engine.context.jpegRepresentation(of: out, colorSpace: sRGB, options: [key: 0.92])
                }
                guard let jpeg else {
                    updateLive(id) { $0.failed = true }
                    finishOne(toast: String(localized: "Impossibile elaborare la foto."))
                    return
                }
                if let liveID, livePhotoIdentifier(in: jpeg) != liveID {
                    // L'identificatore non è finito nel file: il filmato non si abbinerebbe
                    DispatchQueue.main.async { self.toast = String(localized: "Live Photo non abbinata alla foto modificata.") }
                }
                if liveID != nil {
                    // Il salvataggio parte quando anche il filmato è pronto
                    updateLive(id) { $0.jpeg = jpeg; $0.original = keepOriginal ? data : nil }
                } else {
                    save(jpeg, original: keepOriginal ? data : nil)
                }
            }
        }
    }

    /// JPEG filtrato con l'identificatore Live Photo nel MakerNote Apple (chiave 17).
    private func liveJPEG(of image: CIImage, identifier: String, colorSpace: CGColorSpace) -> Data? {
        guard let cg = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace),
              let data = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyMakerAppleDictionary: ["17": identifier]
        ]
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Il filmato della Live Photo è pronto: si tiene da parte fino alla fine dello scatto.
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime,
                     photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let id = resolvedSettings.uniqueID
        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            updateLive(id) { $0.awaitingMovie = false }
            return
        }
        // Il filtro della fotocamera scelta si applica anche a ogni fotogramma del filmato
        stateLock.lock(); let captureRecipe = livePending[id]?.recipe; stateLock.unlock()
        let rec = captureRecipe ?? snapshot().0
        let mirrorShot = device?.position == .front && mirrorFront
        Task { [self] in
            let filtered = await filterLiveMovie(at: outputFileURL, stillTime: photoDisplayTime, recipe: rec, mirror: mirrorShot)
            if filtered != nil { try? FileManager.default.removeItem(at: outputFileURL) }
            let final = filtered ?? outputFileURL        // se il filtro non riesce, resta il filmato originale: la Live funziona comunque
            if isLiveCapturePending(id) {
                updateLive(id) { $0.movie = final; $0.awaitingMovie = false }
            } else {
                try? FileManager.default.removeItem(at: final)      // lo scatto è già stato chiuso o scartato
            }
        }
    }

    /// Fine scatto: se il filmato non è arrivato, la foto filtrata viene salvata comunque (senza Live).
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let id = resolvedSettings.uniqueID
        stateLock.lock(); let isLive = livePending[id] != nil; stateLock.unlock()
        if isLive { updateLive(id) { $0.ended = true; if error != nil { $0.awaitingMovie = false } } }
    }
}

// MARK: - Live Photo: filtro sul filmato
extension CameraManager {

    /// Applica la fotocamera (filtri, colore, grana, cornice…) a ogni fotogramma del filmato della Live Photo.
    /// Mantiene l'identificatore di abbinamento e la traccia "still-image-time", necessari perché Foto lo riconosca come Live.
    /// Restituisce nil se qualcosa non riesce (si userà il filmato originale).
    fileprivate func filterLiveMovie(at url: URL, stillTime: CMTime, recipe rec: CameraRecipe, mirror: Bool) async -> URL? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let frameDuration = try await track.load(.minFrameDuration)
            let start = try await track.load(.timeRange).start
            let metadata = try await asset.load(.metadata)

            // Identificatore di abbinamento già presente nel filmato originale
            var identifier: String?
            for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
                identifier = try await item.load(.stringValue)
            }
            guard let identifier else { return nil }

            // Dimensione del fotogramma dritto (con la rotazione del filmato) e dopo il filtro (ritaglio, cornice, risoluzione)
            let upright = natural.applying(transform)
            let source = CGRect(x: 0, y: 0, width: abs(upright.width), height: abs(upright.height))
            let probe = engine.render(CIImage(color: .black).cropped(to: source), mask: nil, recipe: rec,
                                      flashOn: false, time: 0, quality: .preview)
            let width = max(2, Int(probe.extent.width.rounded()) / 2 * 2)
            let height = max(2, Int(probe.extent.height.rounded()) / 2 * 2)
            let outRect = CGRect(x: 0, y: 0, width: width, height: height)

            let composition = AVMutableVideoComposition(asset: asset) { [engine] request in
                let frame = mirror ? request.sourceImage.oriented(.upMirrored) : request.sourceImage
                let out = engine.render(frame, mask: nil, recipe: rec, flashOn: false,
                                        time: request.compositionTime.seconds, quality: .preview)
                request.finish(with: out.cropped(to: outRect), context: nil)
            }
            composition.renderSize = outRect.size

            let reader = try AVAssetReader(asset: asset)
            let readerOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            readerOutput.videoComposition = composition
            guard reader.canAdd(readerOutput) else { return nil }
            reader.add(readerOutput)

            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
            let idItem = AVMutableMetadataItem()
            idItem.identifier = .quickTimeMetadataContentIdentifier
            idItem.dataType = "com.apple.metadata.datatype.UTF-8"
            idItem.value = identifier as NSString
            writer.metadata = [idItem]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { return nil }
            writer.add(videoInput)

            // Traccia "still-image-time": indica a Foto quale fotogramma è la foto
            let spec: [String: Any] = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"]
            var format: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &format)
            let stillInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            let stillAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: stillInput)
            guard writer.canAdd(stillInput) else { return nil }
            writer.add(stillInput)

            guard writer.startWriting(), reader.startReading() else {
                try? FileManager.default.removeItem(at: outURL)      // il file può essere già stato creato a metà
                return nil
            }
            writer.startSession(atSourceTime: start)

            let stillItem = AVMutableMetadataItem()
            stillItem.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
            stillItem.dataType = "com.apple.metadata.datatype.int8"
            stillItem.value = 0 as NSNumber
            stillAdaptor.append(AVTimedMetadataGroup(
                items: [stillItem], timeRange: CMTimeRange(start: stillTime.isValid ? stillTime : start, duration: frameDuration)))
            stillInput.markAsFinished()

            // Copia i fotogrammi filtrati nel nuovo filmato. Lettore e scrittore sono usati solo dalla coda dedicata:
            // il contenitore dice al compilatore che il passaggio tra contesti è sicuro.
            let pump = FramePump(input: videoInput, output: readerOutput)
            let queue = DispatchQueue(label: "retrocam.livemovie")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                pump.input.requestMediaDataWhenReady(on: queue) {
                    while pump.input.isReadyForMoreMediaData {
                        if let buffer = pump.output.copyNextSampleBuffer() {
                            if !pump.input.append(buffer) { pump.input.markAsFinished(); done.resume(); return }
                        } else {
                            pump.input.markAsFinished(); done.resume(); return
                        }
                    }
                }
            }
            await writer.finishWriting()
            guard writer.status == .completed, reader.status != .failed else {
                try? FileManager.default.removeItem(at: outURL)
                return nil
            }
            return outURL
        } catch {
            return nil
        }
    }
}

/// Coppia scrittore/lettore del filmato Live, usata da una sola coda alla volta.
private final class FramePump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderVideoCompositionOutput
    init(input: AVAssetWriterInput, output: AVAssetReaderVideoCompositionOutput) {
        self.input = input; self.output = output
    }
}
