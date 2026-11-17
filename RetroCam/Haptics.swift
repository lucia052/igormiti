import UIKit

/// Feedback aptici centralizzati. L'utente può disattivarli (chiave "hapticsEnabled").
/// Mappa gli eventi dell'app sui generatori UIKit (selection / impact / notification).
@MainActor
final class Haptics {
    static let shared = Haptics()

    private let selectionGen = UISelectionFeedbackGenerator()
    private let lightGen  = UIImpactFeedbackGenerator(style: .light)
    private let softGen   = UIImpactFeedbackGenerator(style: .soft)
    private let rigidGen  = UIImpactFeedbackGenerator(style: .rigid)
    private let heavyGen  = UIImpactFeedbackGenerator(style: .heavy)
    private let notifyGen = UINotificationFeedbackGenerator()

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Chiamala all'avvio e prima di interazioni intense per ridurre la latenza.
    func prepare() {
        guard isEnabled else { return }
        selectionGen.prepare(); rigidGen.prepare(); heavyGen.prepare(); softGen.prepare()
    }

    // MARK: UI generica
    func selection()    { guard isEnabled else { return }; selectionGen.selectionChanged() }
    func tap()          { guard isEnabled else { return }; lightGen.impactOccurred(intensity: 0.7) }
    func success()      { guard isEnabled else { return }; notifyGen.notificationOccurred(.success) }
    func warning()      { guard isEnabled else { return }; notifyGen.notificationOccurred(.warning) }
    func timerTick()    { guard isEnabled else { return }; lightGen.impactOccurred(intensity: 0.5) }

    // MARK: Scatto
    /// Pressione del pulsante: morbida, "premi a metà corsa".
    func shutterPress() { guard isEnabled else { return }; softGen.impactOccurred(intensity: 0.6) }

    /// Rilascio: doppio colpo (specchio + tendina), come un otturatore meccanico.
    func shutterClick() {
        guard isEnabled else { return }
        heavyGen.impactOccurred(intensity: 1.0)
        Task {
            try? await Task.sleep(for: .milliseconds(70))
            rigidGen.impactOccurred(intensity: 0.65)
        }
    }

    // MARK: Messa a fuoco
    func focusLock()    { guard isEnabled else { return }; rigidGen.impactOccurred(intensity: 0.8) }

    // MARK: Ghiera
    func ringGrab()     { guard isEnabled else { return }; softGen.impactOccurred(intensity: 0.5) }
    /// "Scatto" meccanico a ogni tacca della ghiera.
    func ringTick()     { guard isEnabled else { return }; rigidGen.impactOccurred(intensity: 0.4); rigidGen.prepare() }
    /// Fine corsa (vicino / infinito).
    func ringLimit()    { guard isEnabled else { return }; heavyGen.impactOccurred(intensity: 0.9) }
}
