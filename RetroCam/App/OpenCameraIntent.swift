import AppIntents

/// Apre LumenCam direttamente sul mirino. Si assegna al tasto azione da
/// Impostazioni › Tasto azione › Comando rapido › LumenCam (oppure da Comandi rapidi).
struct OpenCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Apri LumenCam"
    static let description = IntentDescription("Apre la fotocamera di LumenCam.")

    // Deprecato da iOS 26 in favore di supportedModes, ma funziona su tutte le versioni supportate
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Rende il comando visibile in Impostazioni › Tasto azione e in Siri senza configurazione.
struct RetroCamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCameraIntent(),
            phrases: [
                "Apri \(.applicationName)",
                "Scatta con \(.applicationName)"
            ],
            shortTitle: "Apri LumenCam",
            systemImageName: "camera.aperture")
    }
}
