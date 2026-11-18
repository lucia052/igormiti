import SwiftUI
import AVKit

/// Schermata unica: mirino a tutto schermo, controlli in vetro, ghiera opzionale, modale fotocamere.
/// Si adatta all'orientamento come l'app Fotocamera: in verticale controlli sopra e sotto, in orizzontale ai lati.
struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @AppStorage("focusRingEnabled") private var ringEnabled = true
    @AppStorage("gridEnabled") private var gridEnabled = false
    @AppStorage("levelEnabled") private var levelEnabled = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPicker = false
    @State private var timerIndex = 0
    @State private var countdown: Int?
    @State private var timerTask: Task<Void, Never>?
    @State private var shutterFlash = false
    @State private var flashIsWhite = true
    @State private var tapPoint: CGPoint?
    @State private var tapToken = UUID()
    @State private var dragBaseBias: Float?
    @State private var pinchBase: CGFloat?
    @State private var thumbPop = false
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @State private var focusSelection = false          // AF/MF mostrato: cambia subito, l'obiettivo si adegua dopo
    @Namespace private var focusNamespace

    private let timerOptions = [0, 3, 10]
    private var isLandscape: Bool { interfaceOrientation.isLandscape }

    var body: some View {
        ZStack {
            // Il mirino resta sempre scuro (come l'app Fotocamera di iOS: i comandi stanno sopra l'immagine);
            // schermata di permesso e impostazioni seguono invece il tema chiaro/scuro del sistema.
            (camera.authorization == .denied ? Color(.systemBackground) : Color.black).ignoresSafeArea()
            if camera.authorization == .denied {
                CameraAccessView()
            } else {
                cameraUI.environment(\.colorScheme, .dark)
            }
        }
        .animation(.spring(duration: 0.35), value: focusSelection)
        .animation(.easeInOut(duration: 0.25), value: camera.toast)
        .sheet(isPresented: $showPicker) { CameraPickerSheet(camera: camera) }
        .task { camera.start(); Haptics.shared.prepare(); SoundFX.shared.prepare() }
        .task { await trackOrientation() }
        // Cambio di dimensioni = rotazione dell'interfaccia
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _, _ in refreshOrientation() }
        })
        // Camera Control / tasti volume: scatta al rilascio. Disattivato con il modale aperto o senza permesso,
        // così il tasto torna al comportamento di sistema invece di restare "morto".
        .modifier(CameraButtonCapture(isEnabled: camera.authorization == .authorized && !showPicker,
                                      action: shoot))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        .onChange(of: camera.saveCounter) { _, _ in
            Haptics.shared.success(); popThumbnail()
        }
        .onChange(of: camera.toast) { _, message in
            guard message != nil else { return }
            Haptics.shared.warning()
            Task {
                try? await Task.sleep(for: .seconds(3))
                camera.toast = nil
            }
        }
        .onChange(of: ringEnabled) { _, on in if !on { camera.setManualFocus(false) } }
        // Cambi dall'esterno (frontale, ghiera disattivata…): l'interfaccia segue lo stato reale
        .onChange(of: camera.manualFocus) { _, manual in
            if focusSelection != manual { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { focusSelection = manual } }
        }
        .statusBarHidden()
    }

    // MARK: Orientamento
    private func trackOrientation() async {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        refreshOrientation()
        // Passando da orizzontale sinistra a destra le dimensioni non cambiano: serve anche la notifica del dispositivo
        for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
            try? await Task.sleep(for: .milliseconds(350))      // il sistema aggiorna l'interfaccia poco dopo
            refreshOrientation()
        }
    }

    private func refreshOrientation() {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        let o = scene?.interfaceOrientation ?? .portrait
        guard o != .unknown else { return }
        interfaceOrientation = o
        camera.setInterfaceOrientation(o)
    }

    private var cameraUI: some View {
        ZStack {
            viewfinder
            if gridEnabled {
                GridOverlay().ignoresSafeArea().allowsHitTesting(false)
            }
            // Livella (bilanciamento): indica se la foto è dritta; si attiva dal suo pulsante, indipendente dalla griglia
            if levelEnabled && !isLandscape { LevelIndicator() }
            if isLandscape { landscapeLayer } else { topLayer }

            focusRing

            if !isLandscape { bottomLayer }
            zoomSliderLayer

            if let n = countdown {
                Text("\(n)").font(.system(size: 120, weight: .thin, design: .rounded))
                    .foregroundStyle(.white).shadow(radius: 10)
                    .allowsHitTesting(false)
            }
            Color(white: flashIsWhite ? 1 : 0)
                .opacity(shutterFlash ? (flashIsWhite ? 0.9 : 0.5) : 0)
                .ignoresSafeArea().allowsHitTesting(false)
        }
    }

    // MARK: Mirino
    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                ViewfinderLayer(preview: camera.preview,
                                pixelated: camera.recipe.pixelated,
                                square: camera.recipe.cropSquare)
                if let p = tapPoint, !camera.manualFocus {
                    FocusReticle(bias: camera.exposureBias)
                        .position(p)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in focusTap(at: v.location, in: geo.size) })
            .simultaneousGesture(exposureDrag)
            .simultaneousGesture(pinch)
            .simultaneousGesture(swipeToSwitch)
        }
        .ignoresSafeArea()
    }

    /// Pizzico: zoom libero, ottico tra gli obiettivi e digitale oltre.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil { pinchBase = camera.zoom }
                camera.setZoom((pinchBase ?? 1) * v.magnification, ramp: false)
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// Swipe orizzontale sul mirino: passa alla fotocamera precedente o successiva.
    private var swipeToSwitch: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { v in
                // Solo swipe netti e orizzontali; non durante regolazione di esposizione o messa a fuoco manuale
                guard tapPoint == nil, !camera.manualFocus, timerTask == nil,
                      abs(v.translation.width) > 80,
                      abs(v.translation.width) > abs(v.translation.height) * 2 else { return }
                switchCamera(by: v.translation.width < 0 ? 1 : -1)
            }
    }

    private func switchCamera(by step: Int) {
        let all = CameraRecipe.all
        let currentID = camera.recipe.baseID ?? camera.recipe.id
        guard let i = all.firstIndex(where: { $0.id == currentID }) else { return }
        let next = all[(i + step + all.count) % all.count]
        Haptics.shared.selection()
        withAnimation(.easeInOut(duration: 0.2)) { camera.recipe = next }
    }

    private func focusTap(at p: CGPoint, in size: CGSize) {
        guard !camera.manualFocus, let img = camera.preview.image else { return }
        // Il riquadro scivola con una molla verso il nuovo punto (e si restringe, come nell'app Fotocamera)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { tapPoint = p }
        Haptics.shared.focusLock(); SoundFX.shared.focusBeep()

        // Punto dentro l'immagine mostrata: riempie lo schermo (ritaglia i bordi), la Polaroid quadrata sta intera
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = camera.recipe.cropSquare ? min(size.width / iw, size.height / ih) : max(size.width / iw, size.height / ih)
        var u = (p.x - (size.width - iw * s) / 2) / (iw * s)
        var v = (p.y - (size.height - ih * s) / 2) / (ih * s)
        // Cornice istantanea (Polaroid): l'immagine mostrata include i bordi di carta; il tocco va riportato sulla sola foto.
        // Foto quadrata di lato w, bordo b = 3,5% di w a sinistra, destra e sopra (l'immagine è larga w + 2b).
        if camera.recipe.frame == .instant {
            let w = iw / 1.07, b = 0.035 * w
            u = (u * iw - b) / w
            v = (v * ih - b) / w
        }
        u = min(max(u, 0), 1); v = min(max(v, 0), 1)

        // Coordinate del sensore (orientato in orizzontale): dipendono da come è ruotata l'interfaccia.
        // Sulla frontale l'immagine è specchiata solo se l'impostazione "Specchia la frontale" è attiva.
        let front = camera.isFront && mirrorFront
        let point: CGPoint
        switch interfaceOrientation {
        case .landscapeRight: point = CGPoint(x: front ? 1 - u : u, y: v)
        case .landscapeLeft:  point = CGPoint(x: front ? u : 1 - u, y: 1 - v)
        default:              point = CGPoint(x: v, y: front ? u : 1 - u)
        }
        camera.focus(atDevicePoint: point)
        scheduleReticleHide()
    }

    private func scheduleReticleHide() {
        let token = UUID()
        tapToken = token
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if tapToken == token { withAnimation { tapPoint = nil } }
        }
    }

    /// Dopo un tap, trascinare in verticale regola l'esposizione.
    private var exposureDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard tapPoint != nil, !camera.manualFocus else { return }
                if dragBaseBias == nil { dragBaseBias = camera.exposureBias }
                camera.setExposureBias((dragBaseBias ?? 0) - Float(v.translation.height / 45))
                scheduleReticleHide()
            }
            .onEnded { _ in dragBaseBias = nil }
    }

    // MARK: Pulsanti (condivisi tra i due layout)
    private var flashButton: some View {
        Button {
            camera.flashEnabled.toggle(); Haptics.shared.selection(); SoundFX.shared.toggle(camera.flashEnabled)
        } label: {
            Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(camera.flashEnabled && camera.recipe.flash != nil ? Color.yellow : Color.white)
                .frame(width: 44, height: 44)
        }
        .disabled(camera.recipe.flash == nil)
        .opacity(camera.recipe.flash == nil ? 0.4 : 1)
        .glassCircle()
        .accessibilityLabel("Flash")
    }

    /// Pulsante in alto: mostra la fotocamera attiva e, al tocco, apre l'elenco per sceglierne un'altra.
    private var nameCapsule: some View {
        let currentID = camera.recipe.baseID ?? camera.recipe.id
        return Menu {
            ForEach(CameraRecipe.all) { r in
                Button {
                    guard r.id != currentID else { return }
                    Haptics.shared.selection()
                    withAnimation(.easeInOut(duration: 0.2)) { camera.recipe = r }
                } label: {
                    if r.id == currentID {
                        Label(r.name, systemImage: "checkmark")
                    } else {
                        Label(r.name, systemImage: r.symbol)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: camera.recipe.symbol)
                Text(camera.recipe.name).fontWeight(.semibold)
                Text(camera.recipe.aspectLabel).foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        }
        .nativeGlassButton()
        .accessibilityLabel("Scegli fotocamera")
        .accessibilityValue(camera.recipe.name)
    }

    private var timerButton: some View {
        Button {
            timerIndex = (timerIndex + 1) % timerOptions.count
            Haptics.shared.selection()
        } label: {
            ZStack {
                if timerOptions[timerIndex] == 0 {
                    Image(systemName: "timer")
                } else {
                    Text("\(timerOptions[timerIndex])s")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.yellow)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44)
        }
        .glassCircle()
        .accessibilityLabel("Timer")
        .accessibilityValue(timerOptions[timerIndex] == 0 ? "Spento" : "\(timerOptions[timerIndex]) secondi")
    }

    /// Livella: mostra se il telefono è dritto.
    private var levelButton: some View {
        Button {
            levelEnabled.toggle(); Haptics.shared.selection(); SoundFX.shared.toggle(levelEnabled)
        } label: {
            Image(systemName: "level")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(levelEnabled ? Color.yellow : Color.white)
                .frame(width: 44, height: 44)
        }
        .glassCircle()
        .accessibilityLabel("Livella")
        .accessibilityValue(levelEnabled ? "Attiva" : "Spenta")
    }

    private var gridButton: some View {
        Button {
            gridEnabled.toggle(); Haptics.shared.selection(); SoundFX.shared.toggle(gridEnabled)
        } label: {
            Image(systemName: "squareshape.split.3x3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(gridEnabled ? Color.yellow : Color.white)
                .frame(width: 44, height: 44)
        }
        .glassCircle()
        .accessibilityLabel("Griglia")
        .accessibilityValue(gridEnabled ? "Attiva" : "Spenta")
    }

    /// Live Photo: visibile solo se l'obiettivo attivo la supporta.
    @ViewBuilder private var liveButton: some View {
        if camera.livePhotoSupported {
            Button {
                camera.livePhotoEnabled.toggle(); Haptics.shared.selection(); SoundFX.shared.toggle(camera.livePhotoEnabled)
            } label: {
                Image(systemName: camera.livePhotoEnabled ? "livephoto" : "livephoto.slash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(camera.livePhotoEnabled ? Color.yellow : Color.white)
                    .frame(width: 44, height: 44)
            }
            .glassCircle()
            .accessibilityLabel("Live Photo")
            .accessibilityValue(camera.livePhotoEnabled ? "Attiva" : "Spenta")
        }
    }

    private var flipButton: some View {
        Button {
            Haptics.shared.tap(); camera.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .glassCircle()
        .accessibilityLabel("Cambia fotocamera")
    }

    private var galleryButton: some View {
        Button {
            Haptics.shared.tap()
            if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        } label: {
            ZStack {
                Group {
                    if let img = camera.lastPhoto {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if camera.isProcessing {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 56, height: 56)
                    ProgressView().tint(.white)
                }
            }
            .scaleEffect(thumbPop ? 1.15 : 1)
        }
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel("Galleria")
    }

    private var shutterButton: some View {
        Button(action: shoot) { ShutterLabel(armed: timerTask != nil) }
            .buttonStyle(ShutterStyle())
            .accessibilityLabel(timerTask != nil ? "Annulla timer" : "Scatta")
    }

    private var filtersButton: some View {
        Button {
            Haptics.shared.tap(); showPicker = true
        } label: {
            // Sei pallini su due righe
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(.white).frame(width: 7, height: 7) }
                    }
                }
            }
            .frame(width: 56, height: 56)
        }
        .glassCircle()
        .accessibilityLabel("Impostazioni")
    }

    @ViewBuilder private var toastView: some View {
        if let message = camera.toast {
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Layout verticale
    private var topLayer: some View {
        VStack(spacing: 10) {
            // In alto: flash (sinistra), scelta del look (centro) e timer (destra)
            // Tutto sulla stessa linea, centrato in verticale (i due cerchi sono alti 44, la capsula 36)
            GlassGroup(spacing: 16) {
                HStack(alignment: .center) {
                    flashButton
                    Spacer()
                    nameCapsule
                    Spacer()
                    timerButton
                }
                .foregroundStyle(.white)
            }
            toastView
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 20)
    }

    /// Livella (sopra) e Live Photo (sotto): due pulsanti separati, ciascuno col proprio cerchio di vetro.
    private var topBar: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                levelButton
                liveButton
            }
            .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.2), value: camera.livePhotoSupported)
    }

    @ViewBuilder private var focusRing: some View {
        if ringEnabled && focusSelection {
            FocusRingView(lensPosition: $camera.lensPosition, maxDiopters: camera.maxDiopters) {
                camera.applyLensPosition($0)
            }
            .frame(width: isLandscape ? 250 : 220, height: isLandscape ? 250 : 220)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    /// Zoom manuale: ghiera verticale nello stile di quella del fuoco, sul bordo destro. Compare solo in MF.
    /// Trascinando in alto si ingrandisce; un tocco sul valore torna a 1×.
    @ViewBuilder private var zoomSliderLayer: some View {
        if ringEnabled && focusSelection {
            HStack {
                Spacer()
                ZoomDialView(zoom: camera.zoom,
                             minZoom: camera.zoomFloor,
                             maxZoom: 10,
                             stops: camera.lensStops) { camera.setZoom($0, ramp: false) } onReset: {
                    Haptics.shared.selection(); camera.setZoom(1)
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            .padding(.trailing, isLandscape ? 110 : 10)
        }
    }

    private var bottomLayer: some View {
        VStack(spacing: 18) {
            Spacer()
            Text(camera.hudText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            // Riga sopra l'otturatore: comandi (sinistra), AF/MF (centro), cambio frontale/posteriore (destra)
            ZStack {
                focusModeToggle
                HStack {
                    topBar
                    Spacer()
                    flipButton.foregroundStyle(.white)
                }
                .padding(.horizontal, 28)
            }
            bottomBar
        }
        .padding(.bottom, 36)
    }

    private var bottomBar: some View {
        HStack {
            galleryButton
            Spacer()
            shutterButton
            Spacer()
            filtersButton
        }
        .padding(.horizontal, 28)
    }

    // MARK: Layout orizzontale (come l'app Fotocamera: scatto sul lato, comandi in colonna)
    private var landscapeLayer: some View {
        ZStack {
            HStack {
                GlassGroup(spacing: 14) {
                    VStack(spacing: 14) {
                        flashButton
                        timerButton
                        gridButton
                        liveButton
                        flipButton
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                GlassGroup(spacing: 16) {
                    VStack(spacing: 16) {
                        filtersButton
                        shutterButton
                        galleryButton
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VStack(spacing: 8) {
                nameCapsule.foregroundStyle(.white)
                toastView
                Spacer()
            }
            .padding(.vertical, 8)

            // AF/MF a sinistra della ghiera (che sta al centro, 250 pt, con l'etichetta MIN sul lato sinistro)
            focusModeToggle.offset(x: -235)
        }
    }

    /// Selettore AF/MF: due segmenti su vetro, con colori espliciti così resta leggibile sopra il mirino
    /// con qualunque tema del sistema (un Picker segmentato di UIKit segue il tema e può sparire sul vetro scuro).
    private var focusModeToggle: some View {
        GlassGroup {
            HStack(spacing: 2) {
                focusSegment("AF", selected: !focusSelection) { setFocus(manual: false) }
                focusSegment("MF", selected: focusSelection, enabled: canFocusManually) { setFocus(manual: true) }
            }
            .padding(3)
            .glassCapsule()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Messa a fuoco")
    }

    /// Il fuoco manuale c'è solo sulla posteriore e con la ghiera attiva nelle impostazioni. Il selettore resta sempre visibile:
    /// altrimenti, sulla frontale o con la ghiera spenta, sembra che sia sparito.
    private var canFocusManually: Bool { ringEnabled && !camera.isFront }

    private func setFocus(manual on: Bool) {
        guard on != focusSelection else { return }
        // Risposta immediata: l'indicatore scivola subito sul nuovo segmento e la ghiera compare/sparisce con l'animazione,
        // mentre il cambio di obiettivo (che richiede un attimo) avviene in background
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { focusSelection = on }
        Haptics.shared.selection(); SoundFX.shared.toggle(on)
        camera.setManualFocus(on) { applied in
            // Se il fuoco manuale non è disponibile, torna ad AF
            if applied != on { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { focusSelection = applied } }
        }
    }

    private func focusSegment(_ title: LocalizedStringKey, selected: Bool, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 48, height: 28)
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                .background {
                    // Un solo indicatore giallo che scivola da un segmento all'altro
                    if selected { Capsule().fill(Color.yellow).matchedGeometryEffect(id: "focusHighlight", in: focusNamespace) }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func popThumbnail() {
        withAnimation(.spring(duration: 0.25)) { thumbPop = true }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(duration: 0.3)) { thumbPop = false }
        }
    }

    // MARK: Scatto
    private func shoot() {
        // Secondo tocco durante il conto alla rovescia: annulla
        if timerTask != nil {
            timerTask?.cancel(); timerTask = nil; countdown = nil
            Haptics.shared.selection()
            return
        }
        let seconds = timerOptions[timerIndex]
        guard seconds > 0 else { fire(); return }
        timerTask = Task {
            for i in (1...seconds).reversed() {
                countdown = i; Haptics.shared.timerTick(final: i == 1); SoundFX.shared.timerTick()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            timerTask = nil
            fire()
        }
    }

    private func fire() {
        Haptics.shared.shutterClick(); SoundFX.shared.shutter()
        let white = camera.flashEnabled && camera.recipe.flash != nil
        flashIsWhite = white
        withAnimation(.easeOut(duration: 0.08)) { shutterFlash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(white ? 120 : 70))
            withAnimation(.easeIn(duration: 0.25)) { shutterFlash = false }
        }
        camera.capturePhoto()
    }
}

// MARK: - Camera Control / tasti volume

/// Scatta al rilascio del Camera Control (iPhone 16+), dei tasti volume e dell'Action button.
/// Da iOS 26 disattiva il suono di sistema, perché l'app riproduce già il suo click.
private struct CameraButtonCapture: ViewModifier {
    var isEnabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.onCameraCaptureEvent(isEnabled: isEnabled, defaultSoundDisabled: true) { event in
                if event.phase == .ended { action() }
            }
        } else if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: isEnabled) { event in
                if event.phase == .ended { action() }
            }
        } else {
            content   // il Camera Control esiste solo su iPhone con iOS 18+
        }
    }
}

// MARK: - Otturatore

private struct ShutterLabel: View {
    var armed = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.9), lineWidth: 3).padding(2)
            Circle().fill(armed ? Color.yellow : Color.white).padding(9)
        }
        .frame(width: 84, height: 84)
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.shared.shutterPress() }
            }
    }
}

// MARK: - Ghiera di zoom verticale

/// Zoom manuale nello stile della ghiera di messa a fuoco: corpo in vetro con zigrinatura che scorre,
/// indice giallo fisso, click aptico a ogni tacca e colpo più forte a fine corsa. Si trascina in verticale:
/// in alto = più zoom. Scala logaritmica (ogni metà corsa è lo stesso rapporto di zoom).
private struct ZoomDialView: View {
    var zoom: CGFloat
    var minZoom: CGFloat
    var maxZoom: CGFloat
    var stops: [CGFloat] = []                   // zoom degli obiettivi veri: la ghiera "si ferma" quando li attraversa
    var onChange: (CGFloat) -> Void
    var onReset: () -> Void

    private let width: CGFloat = 56
    private let height: CGFloat = 230
    private let travel: CGFloat = 480           // punti di scorrimento per l'intera corsa
    private let tickStep: CGFloat = 8           // una tacca ogni 8 punti
    @State private var dragFraction: CGFloat?   // posizione locale durante il trascinamento (il valore reale arriva in ritardo)
    @State private var lastY: CGFloat?
    @State private var lastTick = 0
    @State private var atLimit = false

    private var fraction: CGFloat {
        guard maxZoom > minZoom, minZoom > 0 else { return 0 }
        let f = log(max(zoom, minZoom) / minZoom) / log(maxZoom / minZoom)
        return min(max(f, 0), 1)
    }

    var body: some View {
        let f = dragFraction ?? fraction
        VStack(spacing: 10) {
            ZStack {
                // Corpo della ghiera
                RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: width * 0.3)
                RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)

                // Zigrinatura: scorre insieme al valore
                Canvas { ctx, sz in
                    let midY = sz.height / 2
                    let offset = f * travel
                    let first = Int(((offset - midY) / tickStep).rounded(.down)) - 1
                    let last = Int(((offset + midY) / tickStep).rounded(.up)) + 1
                    for i in first...last {
                        let y = midY - (CGFloat(i) * tickStep - offset)
                        let long = i % 5 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: sz.width * (long ? 0.28 : 0.36), y: y))
                        p.addLine(to: CGPoint(x: sz.width * 0.72 + (long ? sz.width * 0.0 : -sz.width * 0.08), y: y))
                        ctx.stroke(p, with: .color(.white.opacity(long ? 0.9 : 0.55)), lineWidth: long ? 2 : 1.2)
                    }
                }
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                                           .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )

                // Indice fisso
                HStack {
                    ZoomIndex().fill(Color.yellow).frame(width: 12, height: 18).offset(x: -9)
                    Spacer()
                }
                Rectangle().fill(Color.yellow).frame(width: width * 0.5, height: 1.5)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in handle(v.location.y) }
                    .onEnded { _ in lastY = nil; dragFraction = nil; atLimit = false }
            )

            Text(CameraManager.lensLabel((zoom * 10).rounded() / 10))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassCapsule()
                .onTapGesture(perform: onReset)
        }
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue(CameraManager.lensLabel((zoom * 10).rounded() / 10))
        .accessibilityAdjustableAction { dir in
            onChange(min(maxZoom, max(minZoom, zoom * (dir == .increment ? 1.25 : 0.8))))
            Haptics.shared.ringTick()
        }
    }

    private func handle(_ y: CGFloat) {
        guard let last = lastY else {
            lastY = y
            dragFraction = fraction
            lastTick = Int((fraction * travel) / tickStep)
            Haptics.shared.ringGrab()
            return
        }
        lastY = y
        let current = dragFraction ?? fraction
        let new = min(1, max(0, current + (last - y) / travel))     // verso l'alto = più zoom
        guard new != current else { return }
        dragFraction = new
        let oldZoom = minZoom * pow(maxZoom / minZoom, current), newZoom = minZoom * pow(maxZoom / minZoom, new)
        onChange(newZoom)
        // Fermo morbido quando si attraversa un obiettivo vero
        let crossed = stops.contains { ($0 - oldZoom) * ($0 - newZoom) < 0 || $0 == newZoom }

        // Aptica come la ghiera di messa a fuoco: un click per tacca, colpo forte a fine corsa
        let tick = Int((new * travel) / tickStep)
        if crossed { Haptics.shared.detent(); lastTick = tick }
        else if tick != lastTick { lastTick = tick; Haptics.shared.ringTick(major: tick % 5 == 0) }
        let hitLimit = new == 0 || new == 1
        if hitLimit && !atLimit { Haptics.shared.ringLimit() }
        atLimit = hitLimit
    }
}

/// Triangolo giallo fisso che punta alla ghiera.
private struct ZoomIndex: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

#Preview { ContentView() }
