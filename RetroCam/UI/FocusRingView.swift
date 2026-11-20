import SwiftUI

/// Ghiera di messa a fuoco manuale: si ruota col dito, con un "click" aptico a ogni tacca (più netto sulle tacche lunghe),
/// un colpo a fine corsa, sensibilità che segue la velocità (lento = fine) e inerzia al rilascio.
struct FocusRingView: View {
    @Binding var lensPosition: Float      // 0 = vicino ... 1 = infinito
    var maxDiopters: Float
    var onChange: (Float) -> Void

    private let travel: Double = 5 * .pi / 6      // 150° di corsa totale, come una vera ghiera
    private let tickStep: Double = .pi / 30       // una tacca ogni 6°
    @State private var lastAngle: Double?
    @State private var lastTime: CFTimeInterval = 0
    @State private var velocity: Double = 0       // frazioni di corsa al secondo (smussata)
    @State private var inertia = DialInertia()
    @State private var lastTick = 0
    @State private var atLimit = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let rotation = Double(lensPosition) * travel

            ZStack {
                // Corpo della ghiera
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: size * 0.14)
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1).padding(size * 0.14)

                // Zigrinatura: ruota insieme al valore
                Canvas { ctx, sz in
                    let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                    let R = min(sz.width, sz.height) / 2
                    for i in 0..<60 {
                        let a = Double(i) * (.pi * 2 / 60)
                        let long = i % 5 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * R * 0.93, y: c.y + sin(a) * R * 0.93))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * R * (long ? 0.80 : 0.86), y: c.y + sin(a) * R * (long ? 0.80 : 0.86)))
                        ctx.stroke(p, with: .color(.white.opacity(long ? 0.9 : 0.55)), lineWidth: long ? 2 : 1.2)
                    }
                }
                .rotationEffect(.radians(rotation))

                // Indice fisso
                Triangle().fill(Brand.champagne)
                    .frame(width: 18, height: 12)
                    .offset(y: -size / 2 - 8)

                // Riquadro di messa a fuoco + valore
                RoundedRectangle(cornerRadius: 8).stroke(Brand.champagne, lineWidth: 1.5)
                    .frame(width: size * 0.25, height: size * 0.25)
                Text(distanceText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Brand.champagne)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassCapsule()
                    .offset(y: size * 0.22)

                Text("∞").font(.system(size: 16, design: .monospaced)).foregroundStyle(.white)
                    .offset(x: size / 2 + 12)
                Text(minDistanceText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                    .offset(x: -size / 2 - 18)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in handle(v.location, size: size) }
                    .onEnded { _ in release() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Messa a fuoco manuale")
            .accessibilityValue(distanceText)
            .accessibilityAdjustableAction { dir in
                let step: Float = 0.05
                let new = min(1, max(0, lensPosition + (dir == .increment ? step : -step)))
                lensPosition = new; onChange(new); Haptics.shared.ringTick(major: true)
            }
        }
    }

    private func handle(_ loc: CGPoint, size: CGFloat) {
        let now = CACurrentMediaTime()
        let dx = loc.x - size / 2, dy = loc.y - size / 2
        let dist = hypot(dx, dy), angle = atan2(dy, dx)

        // Il gesto parte da qualunque punto dell'anello, anche largo (non dal centro, dove l'angolo è instabile)
        if lastAngle == nil {
            guard dist > size * 0.18, dist < size * 0.5 else { return }
            inertia.stop()
            lastAngle = angle; lastTime = now; velocity = 0
            lastTick = tickIndex(Double(lensPosition))
            atLimit = lensPosition <= 0 || lensPosition >= 1
            Haptics.shared.ringGrab()
            return
        }
        guard let last = lastAngle, dist > size * 0.12 else { return }
        var d = angle - last
        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
        let dt = max(now - lastTime, 0.001)
        lastAngle = angle; lastTime = now

        // Lento = regolazione fine, veloce = corsa lunga
        let raw = d / travel
        let delta = raw * DialDynamics.gain(forSpeed: abs(raw) / dt)
        velocity = velocity * 0.6 + (delta / dt) * 0.4
        _ = move(by: delta)
    }

    /// Rilascio: se il dito si stava muovendo, la ghiera continua a scorrere e rallenta.
    private func release() {
        let moving = CACurrentMediaTime() - lastTime < 0.08       // dito fermo prima di sollevarlo = nessuna inerzia
        let v = moving ? velocity : 0
        lastAngle = nil; velocity = 0
        inertia.start(velocity: v, step: { move(by: $0) }, finished: { atLimit = false })
    }

    /// Sposta la lente, con aptico a ogni tacca (netto ogni cinque, come le tacche lunghe) e colpo a fine corsa.
    /// Restituisce false quando si è arrivati a fine corsa.
    @discardableResult
    private func move(by delta: Double) -> Bool {
        let old = Double(lensPosition)
        let new = min(1, max(0, old + delta))
        if new != old { lensPosition = Float(new); onChange(Float(new)) }

        let step = tickIndex(new)
        if step != lastTick { lastTick = step; Haptics.shared.ringTick(major: step % 5 == 0) }
        let hitLimit = new == 0 || new == 1
        if hitLimit && !atLimit { Haptics.shared.ringLimit() }
        atLimit = hitLimit
        return !hitLimit
    }

    private func tickIndex(_ value: Double) -> Int { Int(value * travel / tickStep) }

    /// Distanza minima di messa a fuoco di questo modello (da `minimumFocusDistance`), per esempio "12 cm"; senza dato, "MIN".
    private var minDistanceText: String {
        guard maxDiopters > 0.5, maxDiopters < 100 else { return "MIN" }
        let cm = Int((100 / maxDiopters).rounded())
        return "\(cm) cm"
    }

    /// Stima: la posizione della lente è circa lineare in diottrie. Calibra con `minimumFocusDistance`.
    private var distanceText: String {
        let diopters = (1 - lensPosition) * maxDiopters
        if diopters < 0.08 { return "∞" }
        let m = 1 / diopters
        return m < 1 ? "\(Int(m * 100)) cm" : "\(m.formatted(.number.precision(.fractionLength(1)))) m"
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
