import SwiftUI
import CoreMotion

/// Legge la gravità dal giroscopio e ricava l'inclinazione laterale del telefono (in gradi).
final class LevelMotion: ObservableObject {
    @Published var angle: Double = 0
    @Published var isFlat = false

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            // Telefono quasi orizzontale (piatto): l'orizzonte non ha senso
            let flat = abs(g.z) > 0.8
            let raw = atan2(g.x, -g.y) * 180 / .pi
            // Media mobile: toglie il tremolio senza ritardare troppo
            self.angle = self.angle * 0.75 + raw * 0.25
            if self.isFlat != flat { self.isFlat = flat }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Orizzonte artificiale: una linea che resta orizzontale e diventa gialla quando sei in bolla.
struct LevelIndicator: View {
    @StateObject private var motion = LevelMotion()

    var body: some View {
        let isLevel = abs(motion.angle) < 1
        HStack(spacing: 8) {
            Capsule().frame(width: 26, height: 2)
            Capsule().frame(width: 96, height: 2)
                .rotationEffect(.degrees(-motion.angle))
            Capsule().frame(width: 26, height: 2)
        }
        .foregroundStyle(isLevel ? Color.yellow : Color.white.opacity(0.8))
        .shadow(color: .black.opacity(0.4), radius: 2)
        .opacity(motion.isFlat ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isLevel)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
