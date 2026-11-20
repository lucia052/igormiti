import SwiftUI

/// Luminosità in modalità manuale: una barra da −2 a +2 EV. Toccando il valore a sinistra si torna a 0.
struct ExposureStrip: View {
    var bias: Float
    var onChange: (Float) -> Void
    var onReset: () -> Void

    private let range: ClosedRange<Float> = -2...2
    private let inset: CGFloat = 12                 // raggio del cursore: il cursore non esce dalla barra
    @State private var lastStep = 0

    private var label: String { abs(bias) < 0.05 ? "EV 0" : String(format: "EV %+.1f", bias) }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onReset) {
                Text(label)
                    .font(Brand.mono(12))
                    .foregroundStyle(Brand.champagne)
                    .frame(width: 54, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Luminosità")
            .accessibilityValue(label)

            track
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .glassCapsule(interactive: false)
        .frame(maxWidth: 330)
        .padding(.horizontal, 20)
    }

    private var track: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - inset * 2)
            let fraction = CGFloat((bias - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                // Tacche ogni terzo di EV, più lunghe sui valori interi
                Canvas { ctx, size in
                    for i in 0...12 {
                        let x = inset + usable * CGFloat(i) / 12
                        let long = i % 3 == 0
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: size.height / 2 - (long ? 8 : 4)))
                        p.addLine(to: CGPoint(x: x, y: size.height / 2 + (long ? 8 : 4)))
                        ctx.stroke(p, with: .color(.white.opacity(long ? 0.7 : 0.35)), lineWidth: long ? 1.5 : 1)
                    }
                }
                // Cursore: sole del logo, in metallo champagne
                ZStack {
                    Circle().fill(Brand.metal)
                    Image(systemName: "sun.max.fill").font(.system(size: 12)).foregroundStyle(Brand.ink)
                }
                .frame(width: inset * 2, height: inset * 2)
                .offset(x: usable * fraction)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in set(fromX: v.location.x, usable: usable) }
            )
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityLabel("Luminosità")
        .accessibilityValue(label)
        .accessibilityAdjustableAction { dir in
            let new = min(range.upperBound, max(range.lowerBound, bias + (dir == .increment ? 0.33 : -0.33)))
            onChange((new * 10).rounded() / 10)
            Haptics.shared.ringTick()
        }
    }

    private func set(fromX x: CGFloat, usable: CGFloat) {
        let f = Float(min(max((x - inset) / usable, 0), 1))
        var value = range.lowerBound + f * (range.upperBound - range.lowerBound)
        value = (value * 10).rounded() / 10
        if abs(value) < 0.12 { value = 0 }                      // si "aggancia" a 0
        guard value != bias else { return }
        onChange(value)
        let step = Int((value * 3).rounded())                   // un click aptico ogni terzo di EV
        if step != lastStep {
            lastStep = step
            Haptics.shared.ringTick(major: step % 3 == 0)
        }
    }
}
