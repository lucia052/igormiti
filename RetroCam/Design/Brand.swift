import SwiftUI

/// Identità visiva dell'app, presa dal logo: diaframma a sei lamelle in metallo champagne su nero caldo.
enum Brand {
    /// Accento principale (lamelle del logo): sostituisce il giallo di sistema.
    static let champagne = Color(red: 0.90, green: 0.79, blue: 0.66)
    /// Variante più scura, per ombre e bordi dei materiali.
    static let bronze = Color(red: 0.60, green: 0.45, blue: 0.32)
    /// Nero caldo del fondo del logo.
    static let ink = Color(red: 0.043, green: 0.031, blue: 0.027)

    /// Sfumatura metallica delle lamelle.
    static let metal = LinearGradient(colors: [champagne, bronze], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Carattere per i dati tecnici (ƒ/, tempi, zoom): monospaziato, come il resto del mirino.
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Diaframma a sei lamelle. `openness` va da 0 (chiuso) a 1 (aperto): il foro centrale si allarga.
struct ApertureShape: Shape {
    var openness: CGFloat = 0.5
    var blades = 6

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let hole = r * (0.12 + 0.5 * min(max(openness, 0), 1))
        var path = Path()
        for i in 0..<blades {
            let a = CGFloat(i) * 2 * .pi / CGFloat(blades) - .pi / 2
            let step = 2 * CGFloat.pi / CGFloat(blades)
            // Lamella: arco esterno e due lati che puntano al foro, ruotati come nel logo
            let tip = CGPoint(x: c.x + hole * cos(a + step * 1.35), y: c.y + hole * sin(a + step * 1.35))
            let base = CGPoint(x: c.x + hole * cos(a + step * 0.35), y: c.y + hole * sin(a + step * 0.35))
            path.addArc(center: c, radius: r, startAngle: .radians(Double(a)),
                        endAngle: .radians(Double(a + step * 0.92)), clockwise: false)
            path.addLine(to: tip)
            path.addLine(to: base)
            path.closeSubpath()
        }
        return path
    }
}

/// Indicatore di elaborazione: il diaframma gira e si apre e chiude, al posto del cerchio standard.
struct ApertureSpinner: View {
    var size: CGFloat = 26
    @State private var spin = false

    var body: some View {
        ApertureShape(openness: spin ? 0.9 : 0.3)
            .fill(Brand.metal)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 60 : 0))
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: spin)
            .onAppear { spin = true }
            .accessibilityHidden(true)
    }
}
