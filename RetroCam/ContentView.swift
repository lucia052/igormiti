import SwiftUI
import AVKit

/// Schermata unica: mirino a tutto schermo, controlli in vetro, ghiera opzionale, modale fotocamere.
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

    private let timerOptions = [0, 3, 10]

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

    private var cameraUI: some View {
        ZStack {
            viewfinder
            if gridEnabled { GridOverlay().ignoresSafeArea().allowsHitTesting(false) }
            topLayer

            if ringEnabled && camera.manualFocus {
                FocusRingView(lensPosition: $camera.lensPosition, maxDiopters: camera.maxDiopters) {
                    camera.applyLensPosition($0)
                }
                .frame(width: 250, height: 250)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            bottomLayer

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
        }
        .ignoresSafeArea()
    }

    private func focusTap(at p: CGPoint, in size: CGSize) {
        guard !camera.manualFocus else { return }
        withAnimation(.easeOut(duration: 0.2)) { tapPoint = p }
        Haptics.shared.focusLock(); SoundFX.shared.focusBeep()
        // Portrait: coordinate sensore = (y/h, 1 - x/w) per la posteriore, (y/h, x/w) per la frontale (specchiata)
        let nx = p.y / size.height
        let ny = camera.isFront ? p.x / size.width : 1 - p.x / size.width
        camera.focus(atDevicePoint: CGPoint(x: nx, y: ny))
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

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil { pinchBase = camera.zoom }
                camera.setZoom((pinchBase ?? 1) * v.magnification, ramp: false)
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: Livello superiore
    private var topLayer: some View {
        VStack(spacing: 10) {
            topBar
            Text(camera.hudText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            if ringEnabled && !camera.isFront { focusModeToggle }
            if let message = camera.toast {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 20)
    }

    private var topBar: some View {
        GlassGroup(spacing: 16) {
            HStack {
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

                Spacer()
                Text("\(camera.recipe.name) · \(camera.recipe.aspectLabel)")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 36)
                    .glassCapsule()
                Spacer()

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
            .foregroundStyle(.white)
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

    // MARK: Livello inferiore
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

                Spacer()
                zoomPill
                Spacer()

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
            .padding(.horizontal, 28)
        }
    }

    // MARK: Zoom
    private var zoomPill: some View {
        HStack(spacing: 6) {
            ForEach([1, 2, 4], id: \.self) { z in
                let on = abs(camera.zoom - CGFloat(z)) < 0.3
                Button {
                    Haptics.shared.selection(); camera.setZoom(CGFloat(z))
                } label: {
                    Text("\(z)×").font(.system(size: 13, weight: .semibold))
                        .frame(width: 38, height: 30)
                        .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                        .background(on ? Color.white : Color.clear, in: Capsule())
                }
            }
        }
        .padding(4)
        .glassCapsule()
    }

    // MARK: Barra inferiore
    private var bottomBar: some View {
        HStack {
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

            Spacer()
            Button(action: shoot) { ShutterLabel(armed: timerTask != nil) }
                .buttonStyle(ShutterStyle())
                .accessibilityLabel(timerTask != nil ? "Annulla timer" : "Scatta")
            Spacer()

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
        .padding(.horizontal, 28)
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
