import UIKit
import CoreHaptics

/// Feedback aptici centralizzati. L'utente può disattivarli (chiave "hapticsEnabled").
/// Mappa gli eventi dell'app sui generatori UIKit (selection / impact / notification) e, dove l'hardware lo permette,
/// su pattern Core Haptics (otturatore a due tempi). I generatori vengono ri-preparati dopo ogni uso: latenza minima.
@MainActor
final class Haptics {
    static let shared = Haptics()

    private let selectionGen = UISelectionFeedbackGenerator()
    private let lightGen  = UIImpactFeedbackGenerator(style: .light)
    private let softGen   = UIImpactFeedbackGenerator(style: .soft)
    private let rigidGen  = UIImpactFeedbackGenerator(style: .rigid)
    private let heavyGen  = UIImpactFeedbackGenerator(style: .heavy)
    private let notifyGen = UINotificationFeedbackGenerator()

    private var engine: CHHapticEngine?
    private var lastRingTick: CFTimeInterval = 0

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Chiamala all'avvio e prima di interazioni intense per ridurre la latenza.
    func prepare() {
        guard isEnabled else { return }
        selectionGen.prepare(); lightGen.prepare(); rigidGen.prepare(); heavyGen.prepare(); softGen.prepare()
        startEngineIfNeeded()
    }

    // MARK: Core Haptics
    private func startEngineIfNeeded() {
        guard engine == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in Task { @MainActor in try? self?.engine?.start() } }
        try? engine?.start()
    }

    /// Riproduce una sequenza di colpi (tempo relativo in secondi, intensità, nitidezza). false se non disponibile.
    @discardableResult
    private func play(_ hits: [(time: TimeInterval, intensity: Float, sharpness: Float)]) -> Bool {
        startEngineIfNeeded()
        guard let engine else { return false }
        let events = hits.map {
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: $0.intensity),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: $0.sharpness)],
                          relativeTime: $0.time)
        }
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }

    // MARK: UI generica
    func selection()    { guard isEnabled else { return }; selectionGen.selectionChanged(); selectionGen.prepare() }
    func tap()          { guard isEnabled else { return }; lightGen.impactOccurred(intensity: 0.7); lightGen.prepare() }
    func success()      { guard isEnabled else { return }; notifyGen.notificationOccurred(.success); notifyGen.prepare() }
    func warning()      { guard isEnabled else { return }; notifyGen.notificationOccurred(.warning); notifyGen.prepare() }

    /// Conto alla rovescia: leggero a ogni secondo, più deciso sull'ultimo.
    func timerTick(final: Bool = false) {
        guard isEnabled else { return }
        if final {
            rigidGen.impactOccurred(intensity: 0.9); rigidGen.prepare()
        } else {
            lightGen.impactOccurred(intensity: 0.5); lightGen.prepare()
        }
    }

    // MARK: Scatto
    /// Pressione del pulsante: morbida, "premi a metà corsa".
    func shutterPress() { guard isEnabled else { return }; softGen.impactOccurred(intensity: 0.6); softGen.prepare() }

    /// Rilascio: doppio colpo (specchio sordo + tendina secca) con tempi esatti, come un otturatore meccanico.
    func shutterClick() {
        guard isEnabled else { return }
        if play([(0, 1.0, 0.3), (0.06, 0.75, 1.0)]) { return }
        heavyGen.impactOccurred(intensity: 1.0); heavyGen.prepare()
        Task {
            try? await Task.sleep(for: .milliseconds(70))
            rigidGen.impactOccurred(intensity: 0.65); rigidGen.prepare()
        }
    }

    // MARK: Messa a fuoco
    func focusLock()    { guard isEnabled else { return }; rigidGen.impactOccurred(intensity: 0.8); rigidGen.prepare() }

    // MARK: Ghiere
    func ringGrab()     { guard isEnabled else { return }; softGen.impactOccurred(intensity: 0.5); softGen.prepare() }

    /// "Scatto" meccanico a ogni tacca; più netto sulle tacche lunghe. Limitato nel tempo: ruotando in fretta
    /// i colpi non si impastano in un ronzio.
    func ringTick(major: Bool = false) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastRingTick > 0.03 else { return }
        lastRingTick = now
        if major {
            rigidGen.impactOccurred(intensity: 0.7); rigidGen.prepare()
        } else {
            selectionGen.selectionChanged(); selectionGen.prepare()
        }
    }

    /// Fine corsa (vicino / infinito, zoom minimo / massimo).
    func ringLimit()    { guard isEnabled else { return }; heavyGen.impactOccurred(intensity: 0.9); heavyGen.prepare() }

    /// Si attraversa un obiettivo vero (0,5× / 1× / 3×…): fermo morbido, come uno scatto di posizione.
    func detent()       { guard isEnabled else { return }; if !play([(0, 0.8, 0.7)]) { rigidGen.impactOccurred(intensity: 0.8) }; rigidGen.prepare() }

    // MARK: Livella
    /// Il telefono è in bolla: un tocco leggero e nitido.
    func levelAligned() { guard isEnabled else { return }; if !play([(0, 0.55, 0.9)]) { lightGen.impactOccurred(intensity: 0.6) }; lightGen.prepare() }
}
