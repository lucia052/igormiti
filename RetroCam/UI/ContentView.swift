import SwiftUI
import AVKit

/// Schermata unica: mirino a tutto schermo, controlli in vetro, ghiera opzionale, modale fotocamere.
/// Si adatta all'orientamento come l'app Fotocamera: in verticale controlli sopra e sotto, in orizzontale ai lati.
struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @AppStorage("gridEnabled") private var gridEnabled = false
    @AppStorage("levelEnabled") private var levelEnabled = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @Environment(\.scenePhase) private var scenePhase

    private enum TopMenu { case camera, timer }
    @State private var openMenu: TopMenu?              // tendina aperta in alto (fotocamera o timer)
    @State private var showPicker = false
    @State private var timerIndex = 0
    @State private var countdown: Int?
    @State private var timerTask: Task<Void, Never>?
    @State private var shutterFlash = false
    @State private var flashIsWhite = true
    @State private var tapPoint: CGPoint?
    @State private var tapToken = UUID()
    @State private var toastToken = UUID()
    @State private var dragBaseBias: Float?
    @State private var pinchBase: CGFloat?
    @State private var thumbPop = false
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @State private var sideInsets = UIEdgeInsets.zero    // area sicura della finestra (taglio, isola, angoli)
    @State private var focusConfirmed = true           // fuoco automatico bloccato dopo l'ultimo tocco
    @State private var focusToken = UUID()
    @State private var focusSelection = false          // AF/MF mostrato: cambia subito, l'obiettivo si adegua dopo
    @Namespace private var focusNamespace

    private let timerOptions = [0, 3, 5, 10]     // spento, 3, 5, 10 secondi
    private var isLandscape: Bool { interfaceOrientation.isLandscape }
    /// Di quanto avvicinare al bordo destro i pulsanti in alto e in basso in orizzontale: lascia ~16 pt dal bordo fisico,
    /// così non finiscono nella curva degli angoli dello schermo.
    private var landscapeEdgeShift: CGFloat { max(0, sideInsets.right - 16) }

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
        .animation(.smooth(duration: 0.35), value: focusSelection)
        .animation(.smooth(duration: 0.3), value: camera.toast)
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
            // Solo l'ultimo avviso può cancellarsi: prima un avviso vecchio faceva sparire subito quello nuovo
            let token = UUID()
            toastToken = token
            Task {
                try? await Task.sleep(for: .seconds(3))
                if toastToken == token { camera.toast = nil }
            }
        }
        // Cambi dall'esterno (frontale, ghiera disattivata…): l'interfaccia segue lo stato reale
        .onChange(of: camera.manualFocus) { _, manual in
            if focusSelection != manual { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { focusSelection = manual } }
        }
        .statusBarHidden()
    }

    // MARK: Orientamento
    private func trackOrientation() async {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // Il task finisce quando la vista sparisce: si spegne l'accelerometro invece di lasciarlo acceso (batteria)
        defer { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
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
        sideInsets = scene?.keyWindow?.safeAreaInsets ?? .zero
        camera.setInterfaceOrientation(o)
    }

    private var cameraUI: some View {
        ZStack {
            viewfinder
            if gridEnabled {
                GridOverlay().ignoresSafeArea().allowsHitTesting(false)
            }
            // Livella (bilanciamento): indica se la foto è dritta; si attiva dal suo pulsante, indipendente dalla griglia
            if levelEnabled { LevelIndicator(orientation: interfaceOrientation) }
            // Ruotando il telefono i due layout si sciolgono l'uno nell'altro invece di scattare
            if isLandscape { landscapeLayer.transition(.opacity) } else { topLayer.transition(.opacity) }

            focusRing

            if !isLandscape { bottomLayer.transition(.opacity) }
            zoomSliderLayer
            topMenuLayer

            if let n = countdown {
                Text("\(n)").font(.system(size: 120, weight: .thin, design: .rounded))
                    .foregroundStyle(.white).shadow(radius: 10)
                    .allowsHitTesting(false)
            }
            Color(white: flashIsWhite ? 1 : 0)
                .opacity(shutterFlash ? (flashIsWhite ? 0.9 : 0.5) : 0)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        // Animazioni morbide e coerenti (curva "smooth" di sistema) per i cambi di schermata
        .animation(.smooth(duration: 0.35), value: isLandscape)
        .animation(.smooth(duration: 0.3), value: camera.recipe.cropSquare)
        .animation(.smooth(duration: 0.3), value: camera.recipe.id)
        .animation(.smooth(duration: 0.3), value: camera.livePhotoSupported)
        .animation(.smooth(duration: 0.3), value: camera.isFront)
        .animation(.smooth(duration: 0.25), value: levelEnabled)
        .animation(.smooth(duration: 0.25), value: gridEnabled)
        .animation(.smooth(duration: 0.3), value: countdown)
        .animation(.smooth(duration: 0.25), value: openMenu)
    }

    // MARK: Tendine in alto (fotocamera, timer)
    private func toggleMenu(_ menu: TopMenu) {
        Haptics.shared.selection()
        openMenu = openMenu == menu ? nil : menu
    }

    /// Pannello a tendina nello stile del logo. Si chiude toccando fuori, scegliendo una voce o scattando.
    @ViewBuilder private var topMenuLayer: some View {
        if let menu = openMenu {
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { openMenu = nil }
                    .accessibilityHidden(true)
                Group {
                    switch menu {
                    case .camera: cameraMenuPanel
                    case .timer: timerMenuPanel
                    }
                }
                .padding(.top, 56)
                .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    private var cameraMenuPanel: some View {
        let currentID = camera.recipe.baseID ?? camera.recipe.id
        return BrandMenuPanel {
            ForEach(CameraRecipe.all) { r in
                BrandMenuRow(title: Text(r.name), symbol: r.symbol,
                             swatch: r.gradient, selected: r.id == currentID) {
                    if r.id != currentID {
                        Haptics.shared.selection()
                        withAnimation(.smooth(duration: 0.3)) { camera.recipe = r }
                    }
                    openMenu = nil
                }
            }
        }
    }

    /// Timer: quattro tasti in fila (spento, 3, 5, 10 secondi), un solo tocco per scegliere.
    private var timerMenuPanel: some View {
        HStack(spacing: 6) {
            ForEach(timerOptions.indices, id: \.self) { i in
                let seconds = timerOptions[i]
                let selected = i == timerIndex
                Button {
                    if i != timerIndex { timerIndex = i; Haptics.shared.selection() }
                    openMenu = nil
                } label: {
                    VStack(spacing: 3) {
                        if seconds == 0 {
                            Image(systemName: "timer.slash").font(.system(size: 18, weight: .semibold))
                            Text("Spento").font(Brand.mono(11))
                        } else {
                            Text("\(seconds)").font(Brand.mono(22, weight: .bold))
                            Text("sec").font(Brand.mono(11, weight: .regular))
                        }
                    }
                    .foregroundStyle(selected ? Brand.ink : Color.white)
                    .frame(width: 66, height: 62)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.metal)
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(seconds == 0 ? Text("Spento") : Text("\(seconds) secondi"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(8)
        .background(Brand.ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Brand.metal, lineWidth: 0.8).opacity(0.7)
        }
        .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
    }

    // MARK: Mirino
    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                ViewfinderLayer(preview: camera.preview,
                                pixelated: camera.recipe.pixelated,
                                square: camera.recipe.cropSquare)
                    // Durante il cambio AF ↔ MF il mirino si ferma un attimo: lo si vela con una sfocatura che si dissolve,
                    // come nel cambio di obiettivo dell'app Fotocamera, invece di mostrare un fotogramma congelato
                    .blur(radius: camera.isSwitchingLens ? 16 : 0)
                    .scaleEffect(camera.isSwitchingLens ? 1.02 : 1)
                    .animation(.smooth(duration: 0.28), value: camera.isSwitchingLens)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Il riquadro sta in un overlay del contenitore a dimensione schermo, NON dentro lo ZStack dell'immagine:
            // con scaledToFill l'immagine è più larga dello schermo e lo ZStack interno lo è con lei, quindi `position`
            // veniva misurato da un'origine spostata (a sinistra di metà dell'eccedenza) rispetto al punto toccato.
            .overlay {
                if let p = tapPoint, !camera.manualFocus {
                    FocusReticle(bias: camera.exposureBias, searching: !focusConfirmed)
                        .position(p)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in focusTap(at: v.location, in: geo.size) })
            .simultaneousGesture(exposureDrag)
            .simultaneousGesture(pinch)
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

    private func focusTap(at p: CGPoint, in size: CGSize) {
        guard !camera.manualFocus, let img = camera.preview.image else { return }
        Haptics.shared.selection()      // risposta immediata al tocco: prima non c'era nulla finché il fuoco non si bloccava
        // Il riquadro scivola con una molla verso il nuovo punto (e si restringe, come nell'app Fotocamera)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { tapPoint = p }
        focusConfirmed = false     // la conferma (nessun suono né aptico) arriva quando il fuoco è davvero bloccato

        // Punto dentro l'immagine mostrata: riempie lo schermo (ritaglia i bordi), l'istantanea quadrata sta intera
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = camera.recipe.cropSquare ? min(size.width / iw, size.height / ih) : max(size.width / iw, size.height / ih)
        var u = (p.x - (size.width - iw * s) / 2) / (iw * s)
        var v = (p.y - (size.height - ih * s) / 2) / (ih * s)
        // Cornice istantanea: l'immagine mostrata include i bordi di carta; il tocco va riportato sulla sola foto.
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
        confirmFocus()
        scheduleReticleHide()
    }

    /// Aspetta che l'autofocus finisca di cercare (max ~2,5 s) e solo allora conferma: il riquadro diventa giallo (nessun suono né aptico).
    private func confirmFocus() {
        let token = UUID()
        focusToken = token
        Task {
            try? await Task.sleep(for: .milliseconds(250))          // il tempo che la ricerca parta
            var waited = 0
            while camera.isFocusing && waited < 40 && focusToken == token {
                try? await Task.sleep(for: .milliseconds(50)); waited += 1
            }
            guard focusToken == token, tapPoint != nil else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { focusConfirmed = true }
        }
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
                .foregroundStyle(camera.flashEnabled && camera.recipe.flash != nil ? Brand.champagne : Color.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(camera.recipe.flash == nil)
        .opacity(camera.recipe.flash == nil ? 0.4 : 1)
        .glassCircle()
        .accessibilityLabel("Flash")
    }

    /// Pulsante in alto: mostra la fotocamera attiva e, al tocco, apre l'elenco per sceglierne un'altra.
    private var nameCapsule: some View {
        return Button {
            toggleMenu(.camera)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: camera.recipe.symbol)
                Text(camera.recipe.name).font(Brand.mono(14))
                Text(camera.recipe.aspectLabel).font(Brand.mono(12, weight: .regular)).foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(openMenu == .camera ? 180 : 0))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        }
        .nativeGlassButton()
        .accessibilityLabel("Scegli fotocamera")
        .accessibilityValue(camera.recipe.name)
    }

    /// Timer: un tocco apre il menu per scegliere spento, 3, 5 o 10 secondi.
    private var timerButton: some View {
        Button {
            toggleMenu(.timer)
        } label: {
            ZStack {
                if timerOptions[timerIndex] == 0 {
                    Image(systemName: "timer")
                } else {
                    Text("\(timerOptions[timerIndex])s")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.champagne)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 44, height: 44)
                .contentShape(Circle())
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
                .foregroundStyle(levelEnabled ? Brand.champagne : Color.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassCircle()
        .accessibilityLabel("Allineamento orizzontale")
        .accessibilityValue(levelEnabled ? "Attiva" : "Spenta")
    }

    private var gridButton: some View {
        Button {
            gridEnabled.toggle(); Haptics.shared.selection(); SoundFX.shared.toggle(gridEnabled)
        } label: {
            Image(systemName: "squareshape.split.3x3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(gridEnabled ? Brand.champagne : Color.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
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
                    .foregroundStyle(camera.livePhotoEnabled ? Brand.champagne : Color.white)
                    .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .glassCircle()
            .accessibilityLabel("Live Photo")
            .accessibilityValue(camera.livePhotoEnabled ? "Attiva" : "Spenta")
        }
    }

    private var flipButton: some View {
        Button {
            Haptics.shared.tap()
            camera.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
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
                    ApertureSpinner(size: 28)
                }
            }
            .scaleEffect(thumbPop ? 1.15 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            .contentShape(Circle())
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

    /// Pulsante Live Photo, in colonna a sinistra sopra l'otturatore (la livella si attiva dalle impostazioni).
    private var topBar: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                liveButton
            }
            .foregroundStyle(.white)
        }
        .animation(.easeInOut(duration: 0.2), value: camera.livePhotoSupported)
    }

    @ViewBuilder private var focusRing: some View {
        if focusSelection {
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
        if focusSelection {
            HStack {
                Spacer()
                ZoomDialView(zoom: camera.zoom,
                             minZoom: camera.zoomFloor,
                             maxZoom: camera.zoomCeiling,
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
            HUDLabel(model: camera.hud)
            zoomPill
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
                        liveButton
                        flipButton
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                GlassGroup(spacing: 16) {
                    VStack(spacing: 16) {
                        // Impostazioni e galleria stanno in alto e in basso, lontane dal Dynamic Island (al centro del bordo):
                        // si spostano verso il bordo dello schermo, oltre l'area sicura. L'otturatore resta dov'è.
                        filtersButton.offset(x: landscapeEdgeShift)
                        shutterButton
                        galleryButton.offset(x: landscapeEdgeShift)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VStack(spacing: 8) {
                nameCapsule.foregroundStyle(.white)
                toastView
                Spacer()
                zoomPill
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

    /// Il fuoco manuale c'è sempre, anche sulla frontale. Se la lente è a fuoco fisso (frontali più vecchie)
    /// il tocco su MF avvisa invece di non fare nulla.
    private var canFocusManually: Bool { true }

    private func setFocus(manual on: Bool) {
        // Già in AF e tocchi AF: lascia il punto scelto e riprende l'autofocus continuo al centro
        if !on && !focusSelection {
            Haptics.shared.selection()
            withAnimation { tapPoint = nil; focusConfirmed = true }
            camera.resumeAutoFocus()
            return
        }
        guard on != focusSelection else { return }
        if on && !camera.manualFocusSupported {
            camera.toast = String(localized: "Questa fotocamera ha il fuoco fisso: la messa a fuoco manuale non è disponibile.")
            Haptics.shared.warning()
            return
        }
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
                .font(Brand.mono(13, weight: .bold))
                .frame(width: 54, height: 36)
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                .background {
                    // Un solo indicatore giallo che scivola da un segmento all'altro
                    if selected { Capsule().fill(Brand.metal).matchedGeometryEffect(id: "focusHighlight", in: focusNamespace) }
                }
                .contentShape(Capsule())     // senza questo, con lo stile "plain", risponde solo dove c'è il testo
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Zoom rapido (modalità automatica)
    /// Passaggio rapido tra gli obiettivi veri (0,5× 1× 3×…) e le tappe digitali (2× 4×). Solo in AF: in manuale lo zoom
    /// si regola con la ghiera verticale, e il cambio di obiettivo rimetterebbe il fuoco in automatico.
    @ViewBuilder private var zoomPill: some View {
        if !focusSelection && camera.zoomStops.count > 1 {
            GlassGroup(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(camera.zoomStops, id: \.self) { stop in
                        let on = abs(camera.zoom - stop) < 0.1
                        Button {
                            Haptics.shared.selection(); camera.setZoom(stop)
                        } label: {
                            Text(CameraManager.lensLabel(stop))
                                .font(Brand.mono(13))
                                .frame(width: 46, height: 40)
                                .foregroundStyle(on ? Brand.champagne : Color.white.opacity(0.85))
                                .background(on ? Color.white.opacity(0.2) : Color.clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zoom")
                        .accessibilityValue(CameraManager.lensLabel(stop))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(4)
                .glassCapsule()
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
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
        openMenu = nil
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
            Circle().strokeBorder(Brand.metal, lineWidth: 3).padding(2)
            // Il diaframma si chiude quando il timer è armato
            ApertureShape(openness: armed ? 0.15 : 0.55)
                .fill(Brand.metal)
                .padding(10)
                .animation(.spring(duration: 0.3), value: armed)
        }
        .frame(width: 84, height: 84)
        // Il cerchio e il pallino interno lasciano un anello vuoto in mezzo: senza questo, toccare lì non scatta
        .contentShape(Circle())
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
    @State private var lastTime: CFTimeInterval = 0
    @State private var velocity: Double = 0     // frazioni di corsa al secondo (smussata)
    @State private var inertia = DialInertia()
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
                    ZoomIndex().fill(Brand.champagne).frame(width: 12, height: 18).offset(x: -9)
                    Spacer()
                }
                Rectangle().fill(Brand.champagne).frame(width: width * 0.5, height: 1.5)
            }
            .frame(width: width, height: height)
            // Area di tocco più larga della ghiera (14 pt per lato): non serve centrarla col dito
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in handle(v.location.y) }
                    .onEnded { _ in release() }
            )
            .padding(.horizontal, -14)

            Text(CameraManager.lensLabel((zoom * 10).rounded() / 10))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Brand.champagne)
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
        let now = CACurrentMediaTime()
        guard let last = lastY else {
            inertia.stop()
            lastY = y; lastTime = now; velocity = 0
            let start = dragFraction ?? fraction            // se l'inerzia girava ancora, si riparte da dove è arrivata
            dragFraction = start
            lastTick = Int((start * travel) / tickStep)
            atLimit = start <= 0 || start >= 1
            Haptics.shared.ringGrab()
            return
        }
        let dt = max(now - lastTime, 0.001)
        lastY = y; lastTime = now

        // Verso l'alto = più zoom. Lento = regolazione fine, veloce = corsa lunga
        let raw = Double(last - y) / Double(travel)
        let delta = raw * DialDynamics.gain(forSpeed: abs(raw) / dt)
        velocity = velocity * 0.6 + (delta / dt) * 0.4
        _ = move(by: delta)
    }

    /// Rilascio: la ghiera continua a scorrere con inerzia e poi si allinea al valore reale.
    private func release() {
        let moving = CACurrentMediaTime() - lastTime < 0.08
        let v = moving ? velocity : 0
        lastY = nil; velocity = 0
        inertia.start(velocity: v, step: { move(by: $0) }, finished: { dragFraction = nil; atLimit = false })
    }

    /// Sposta lo zoom, con un fermo morbido sugli obiettivi veri, click a ogni tacca (netto ogni cinque) e colpo a fine corsa.
    /// Restituisce false a fine corsa.
    @discardableResult
    private func move(by delta: Double) -> Bool {
        let current = dragFraction ?? fraction
        let new = min(1, max(0, current + CGFloat(delta)))
        guard new != current else { return new > 0 && new < 1 }
        dragFraction = new
        let oldZoom = minZoom * pow(maxZoom / minZoom, current), newZoom = minZoom * pow(maxZoom / minZoom, new)
        onChange(newZoom)
        let crossed = stops.contains { ($0 - oldZoom) * ($0 - newZoom) < 0 || $0 == newZoom }

        let tick = Int((new * travel) / tickStep)
        if crossed { Haptics.shared.detent(); lastTick = tick }
        else if tick != lastTick { lastTick = tick; Haptics.shared.ringTick(major: tick % 5 == 0) }
        let hitLimit = new == 0 || new == 1
        if hitLimit && !atLimit { Haptics.shared.ringLimit() }
        atLimit = hitLimit
        return !hitLimit
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
