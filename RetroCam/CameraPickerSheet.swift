import SwiftUI

/// Modale delle impostazioni (griglia, originale, ghiera, aptica). La fotocamera si sceglie dal pulsante in alto.
struct CameraPickerSheet: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("focusRingEnabled") private var ringEnabled = true
    @AppStorage("gridEnabled") private var gridEnabled = false
    @AppStorage("saveOriginal") private var saveOriginal = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @AppStorage("soundEnabled") private var soundEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section("Scatto") {
                    Toggle("Griglia dei terzi", isOn: $gridEnabled)
                    Toggle("Salva anche l'originale", isOn: $saveOriginal)
                    Toggle("Specchia la fotocamera frontale", isOn: $mirrorFront)
                }
                Section {
                    Toggle("Ghiera di messa a fuoco", isOn: $ringEnabled)
                    Toggle("Feedback aptico", isOn: $hapticsEnabled)
                    Toggle("Effetti sonori", isOn: $soundEnabled)
                } header: {
                    Text("Controlli")
                }
            }
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
        .onChange(of: hapticsEnabled) { _, on in SoundFX.shared.toggle(on); if on { Haptics.shared.selection() } }
        .onChange(of: ringEnabled) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on) }
        .onChange(of: gridEnabled) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on) }
        .onChange(of: soundEnabled) { _, on in if on { SoundFX.shared.toggle(true) } }     // acceso: lo sente; spento: tace
        .onChange(of: saveOriginal) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on) }
        .onChange(of: mirrorFront) { _, on in Haptics.shared.selection(); SoundFX.shared.toggle(on); camera.refreshMirroring() }
    }
}
