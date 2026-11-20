import SwiftUI

/// Modale delle impostazioni (griglia, originale, ghiera, aptica). La fotocamera si sceglie dal pulsante in alto.
struct CameraPickerSheet: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("gridEnabled") private var gridEnabled = false
    @AppStorage("levelEnabled") private var levelEnabled = false
    @AppStorage("saveOriginal") private var saveOriginal = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("photoMegapixels") private var photoMegapixels = 0      // 0 = predefinita per questo telefono
    @AppStorage("videoResolution") private var videoResolution = 720
    @AppStorage("videoFrameRate") private var videoFrameRate = 30
    @AppStorage("videoAudio") private var videoAudio = true

    /// Risoluzione mostrata: quella scelta (o la predefinita), riportata a una che il sensore offre davvero.
    private var effectiveMegapixels: Int {
        let wanted = photoMegapixels > 0 ? photoMegapixels : DeviceProfile.defaultMegapixels
        let options = camera.supportedMegapixels
        return options.last { $0 <= wanted } ?? options.first ?? 12
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Scatto") {
                    Toggle("Griglia dei terzi", isOn: $gridEnabled)
                    Toggle("Allineamento orizzontale", isOn: $levelEnabled)
                    Toggle("Salva anche l'originale", isOn: $saveOriginal)
                    Toggle("Specchia la fotocamera frontale", isOn: $mirrorFront)
                }
                // Solo sui modelli che scattano oltre i 12 MP
                if camera.supportedMegapixels.count > 1 {
                    Section {
                        Picker("Risoluzione", selection: Binding(get: { effectiveMegapixels },
                                                                 set: { photoMegapixels = $0 })) {
                            ForEach(camera.supportedMegapixels, id: \.self) { Text("\($0) MP").tag($0) }
                        }
                    } header: {
                        Text("Foto")
                    }
                }
                Section("Video") {
                    Picker("Risoluzione", selection: $videoResolution) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                    }
                    Picker("Fotogrammi", selection: $videoFrameRate) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                    }
                    Toggle("Registra l'audio", isOn: $videoAudio)
                }
                Section {
                    Toggle("Feedback aptico", isOn: $hapticsEnabled)
                    Toggle("Effetti sonori", isOn: $soundEnabled)
                } header: {
                    Text("Controlli")
                }
                // Firma in fondo alle impostazioni: solo il marchio
                Section {
                    BrandMark(apertureSize: 44, openness: 0.55)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                }
            }
            .tint(Brand.champagne)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Chiudi")
                }
            }
        }
        .presentationDetents([.fraction(0.78), .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .onChange(of: hapticsEnabled) { _, on in SoundFX.shared.toggle(on); if on { Haptics.shared.selection() } }
        .onChange(of: gridEnabled) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on) }
        .onChange(of: levelEnabled) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on) }
        .onChange(of: soundEnabled) { _, on in if on { SoundFX.shared.toggle(true) } }     // acceso: lo sente; spento: tace
        .onChange(of: saveOriginal) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on) }
        .onChange(of: photoMegapixels) { _, _ in Haptics.shared.selection(); camera.refreshPhotoResolution() }
        .onChange(of: videoResolution) { _, _ in Haptics.shared.selection() }      // si legge all'avvio di ogni registrazione
        .onChange(of: videoFrameRate) { _, _ in Haptics.shared.selection(); camera.refreshVideoSettings() }
        .onChange(of: videoAudio) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on); camera.refreshVideoSettings() }
        .onChange(of: mirrorFront) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on); camera.refreshMirroring() }
    }
}
