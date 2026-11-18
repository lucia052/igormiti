import SwiftUI

/// Dinamica condivisa dalle due ghiere (messa a fuoco e zoom).
enum DialDynamics {
    /// Sensibilità secondo la velocità del dito (`speed` = frazioni di corsa al secondo):
    /// lento = regolazione fine (0,5×), veloce = corsa lunga (fino a 2×).
    static func gain(forSpeed speed: Double) -> Double { min(2.0, max(0.5, 0.5 + speed)) }

    /// Velocità massima accettata per l'inerzia (frazioni di corsa al secondo).
    static let maxVelocity = 3.0
}

/// Inerzia al rilascio: la ghiera continua a scorrere e rallenta con dolcezza, come una vera ghiera libera.
@MainActor
final class DialInertia {
    private var task: Task<Void, Never>?

    func stop() { task?.cancel(); task = nil }

    /// - velocity: frazioni di corsa al secondo (con segno).
    /// - step: applica uno spostamento; restituisce false quando la corsa è finita.
    /// - finished: chiamata quando l'inerzia si esaurisce (non se viene interrotta da un nuovo tocco).
    func start(velocity: Double, step: @escaping @MainActor (Double) -> Bool, finished: @escaping @MainActor () -> Void) {
        stop()
        let v0 = max(-DialDynamics.maxVelocity, min(DialDynamics.maxVelocity, velocity))
        guard abs(v0) > 0.2 else { finished(); return }
        task = Task { @MainActor in
            var v = v0
            var last = CACurrentMediaTime()
            while abs(v) > 0.04, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let now = CACurrentMediaTime(), dt = now - last
                last = now
                if !step(v * dt) { break }
                v *= exp(-dt * 4.5)                 // rallenta: ~0,22 s per perdere il 63% della velocità
            }
            if !Task.isCancelled { finished() }
        }
    }
}
