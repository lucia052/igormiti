import SwiftUI

/// Modale di selezione fotocamera + impostazioni (griglia, originale, ghiera, aptica).
struct CameraPickerSheet: View {
    @ObservedObject var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("focusRingEnabled") private var ringEnabled = true
    @AppStorage("gridEnabled") private var gridEnabled = false
    @AppStorage("saveOriginal") private var saveOriginal = false
    @AppStorage("soundEnabled") private var soundEnabled = true

    @State private var lookPrompt = ""
    @State private var isGenerating = false
    @State private var lookError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CameraRecipe.all) { r in
                        Button { choose(r) } label: { row(r) }
                            .buttonStyle(.plain)
                    }
                }
                lookSection
                Section("Scatto") {
                    Toggle("Griglia dei terzi", isOn: $gridEnabled)
                    Toggle("Salva anche l'originale", isOn: $saveOriginal)
                }
                Section("Controlli") {
                    Toggle("Ghiera di messa a fuoco", isOn: $ringEnabled)
                    Toggle("Feedback aptico", isOn: $hapticsEnabled)
                    Toggle("Effetti sonori", isOn: $soundEnabled)
                }
                Section {
                    LabeledContent("Versione", value: appVersion)
                } footer: {
                    Text("Tocca il mirino per mettere a fuoco, poi trascina in verticale per regolare l'esposizione. Pizzica per fare zoom.")
                }
            }
            .navigationTitle("Fotocamere")
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
        .onChange(of: hapticsEnabled) { _, on in if on { Haptics.shared.selection() } }
        .onChange(of: ringEnabled) { _, _ in Haptics.shared.selection() }
        .onChange(of: gridEnabled) { _, _ in Haptics.shared.selection() }
        .onChange(of: saveOriginal) { _, _ in Haptics.shared.selection() }
    }

    // MARK: Look con AI
    private var lookSection: some View {
        Section {
            if camera.recipe.isCustom {
                Button { dismiss() } label: { row(camera.recipe) }
                    .buttonStyle(.plain)
            }
            TextField("Es. tramonto estivo con ombre viola", text: $lookPrompt, axis: .vertical)
                .lineLimit(1...3)
                .disabled(isGenerating)
            Button(action: generateLook) {
                HStack {
                    Label("Crea look", systemImage: "sparkles")
                    if isGenerating { Spacer(); ProgressView() }
                }
            }
            .disabled(isGenerating || lookPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || LookGenerator.unavailableReason != nil)
            if let message = lookError ?? LookGenerator.unavailableReason {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Look con AI")
        } footer: {
            Text("Descrivi uno stile: l'AI sul dispositivo regola colori e ottica della fotocamera scelta. Nessun dato lascia il telefono.")
        }
    }

    private func generateLook() {
        let text = lookPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Parte sempre da una delle fotocamere: un nuovo look sostituisce quello precedente
        let baseID = camera.recipe.baseID ?? camera.recipe.id
        let base = CameraRecipe.all.first { $0.id == baseID } ?? .g7x
        isGenerating = true
        lookError = nil
        Task {
            do {
                camera.recipe = try await LookGenerator.generate(prompt: text, base: base)
                Haptics.shared.success()
                dismiss()
            } catch {
                lookError = (error as? LookGenerator.LookError)?.errorDescription
                    ?? "Non sono riuscito a creare il look. Riprova con una descrizione diversa."
            }
            isGenerating = false
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func row(_ r: CameraRecipe) -> some View {
        HStack(spacing: 14) {
            Image(systemName: r.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: r.gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.headline)
                Text(r.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if camera.recipe.id == r.id {
                Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(camera.recipe.id == r.id ? .isSelected : [])
    }

    private func choose(_ r: CameraRecipe) {
        guard r.id != camera.recipe.id else { dismiss(); return }
        Haptics.shared.selection()
        camera.recipe = r
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            dismiss()
        }
    }
}
