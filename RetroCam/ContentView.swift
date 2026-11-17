import SwiftUI
import AVKit

/// Schermata unica: mirino a tutto schermo, controlli in vetro, ghiera opzionale, modale fotocamere.
/// Si adatta all'orientamento come l'app Fotocamera: in verticale controlli sopra e sotto, in orizzontale ai lati.
struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @AppStorage("focusRingEnabled") private var ringEnabled = true
    @AppStorage("gridEnabled") private var gridEnabled = false
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

    private let timerOptions = [0, 3, 10]
    private var isLandscape: Bool { interfaceOrientation.isLandscape }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorization == .denied {
                CameraAccessView()
            } else {
                cameraUI
            }
        }
        .animation(.spring(duration: 0.35), value: camera.manualFocus)
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
                if !isLandscape { LevelIndicator() }
            }
            if isLandscape { landscapeLayer } else { topLayer }

            if ringEnabled && camera.manualFocus {
                FocusRingView(lensPosition: $camera.lensPosition, maxDiopters: camera.maxDiopters) {
                    camera.applyLensPosition($0)
                }
                .frame(width: 250, height: 250)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if !isLandscape { bottomLayer }

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
        withAnimation(.easeOut(duration: 0.2)) { tapPoint = p }
        Haptics.shared.focusLock(); SoundFX.shared.focusBeep()

        // Punto dentro l'immagine mostrata: riempie lo schermo (ritaglia i bordi), la Polaroid quadrata sta intera
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = camera.recipe.cropSquare ? min(size.width / iw, size.height / ih) : max(size.width / iw, size.height / ih)
        let u = min(max((p.x - (size.width - iw * s) / 2) / (iw * s), 0), 1)
        let v = min(max((p.y - (size.height - ih * s) / 2) / (ih * s), 0), 1)

        // Coordinate del sensore (orientato in orizzontale): dipendono da come è ruotata l'interfaccia.
        // Sulla frontale l'immagine è specchiata.
        let front = camera.isFront
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
            camera.flashEnabled.toggle(); Haptics.shared.selection()
        } label: {
            Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .disabled(camera.recipe.flash == nil)
        .opacity(camera.recipe.flash == nil ? 0.4 : 1)
        .glassCircle()
        .accessibilityLabel("Flash")
    }

    private var nameCapsule: some View {
        Text("\(camera.recipe.name) · \(camera.recipe.aspectLabel)")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).frame(height: 36)
            .glassCapsule()
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

    private var gridButton: some View {
        Button {
            gridEnabled.toggle(); Haptics.shared.selection()
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
            Image(systemName: "camera.filters")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .glassCircle()
        .accessibilityLabel("Scegli fotocamera")
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
            topBar
            Text(camera.hudText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            if ringEnabled && !camera.isFront { focusModeToggle }
            toastView
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 20)
    }

    private var topBar: some View {
        GlassGroup(spacing: 16) {
            HStack {
                flashButton
                Spacer()
                nameCapsule
                Spacer()
                timerButton
            }
            .foregroundStyle(.white)
        }
    }

    private var bottomLayer: some View {
        VStack(spacing: 18) {
            Spacer()
            utilityRow
            bottomBar
        }
        .padding(.bottom, 12)
    }

    private var utilityRow: some View {
        GlassGroup(spacing: 16) {
            HStack {
                gridButton
                Spacer()
                zoomPill
                Spacer()
                flipButton
            }
            .padding(.horizontal, 28)
        }
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
                if ringEnabled && !camera.isFront { focusModeToggle }
                toastView
                Spacer()
                zoomPill
            }
            .padding(.vertical, 8)
        }
    }

    private var focusModeToggle: some View {
        GlassGroup {
            HStack(spacing: 2) {
                modeButton("AF", selected: !camera.manualFocus) { camera.setManualFocus(false) }
                modeButton("MF", selected: camera.manualFocus) { camera.setManualFocus(true) }
            }
            .padding(3)
            .glassCapsule()
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.shared.selection(); action()
        } label: {
            Text(title).font(.system(size: 12, weight: .bold))
                .frame(width: 44, height: 26)
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                .background(selected ? Color.yellow : Color.clear, in: Capsule())
        }
    }

    // MARK: Zoom
    private var zoomPill: some View {
        HStack(spacing: 6) {
            // Obiettivi fisici del telefono (es. 0,5× 1× 3×) più tappe digitali (2× 4×)
            ForEach(camera.zoomStops, id: \.self) { z in
                let on = abs(camera.zoom - z) < 0.1
                Button {
                    Haptics.shared.selection(); camera.setZoom(z)
                } label: {
                    Text(CameraManager.lensLabel(z)).font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 30)
                        .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                        .background(on ? Color.white : Color.clear, in: Capsule())
                }
            }
        }
        .padding(4)
        .glassCapsule()
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
                countdown = i; Haptics.shared.timerTick(); SoundFX.shared.timerTick()
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

#Preview { ContentView() }
