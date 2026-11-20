import SwiftUI

/// Identità visiva dell'app, presa dal logo: diaframma a sei lamelle in metallo champagne su nero caldo.
enum Brand {
    /// Accento principale (lamelle del logo): sostituisce il giallo di sistema.
    static let champagne = Color(red: 0.90, green: 0.79, blue: 0.66)
    /// Variante più scura, per ombre e bordi dei materiali.
    static let bronze = Color(red: 0.60, green: 0.45, blue: 0.32)
    /// Nero caldo del fondo del logo.
    static let ink = Color(red: 0.043, green: 0.031, blue: 0.027)

    /// Riflesso del metallo spazzolato: il punto più chiaro delle lamelle.
    static let highlight = Color(red: 0.99, green: 0.93, blue: 0.82)

    /// Sfumatura metallica delle lamelle: luce, champagne, ombra bronzo (più contrasto di un semplice due colori).
    static let metal = LinearGradient(
        stops: [.init(color: highlight, location: 0), .init(color: champagne, location: 0.35),
                .init(color: bronze, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Nome dell'app, inciso come su una targhetta di fotocamera.
    static let name = "LUMORA"

    /// Carattere per i dati tecnici (ƒ/, tempi, zoom): monospaziato, come il resto del mirino.
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension EnvironmentValues {
    /// Scala globale dei comandi, calcolata sulle dimensioni reali della finestra (1 = iPhone da 393 pt):
    /// su un iPhone compatto i comandi si stringono un po', su iPhone grandi e iPad crescono, senza mai uscire dai limiti.
    @Entry var uiScale: CGFloat = 1
}

enum UIScale {
    /// Scala per una finestra di queste dimensioni, dal lato corto (stabile in verticale e in orizzontale).
    static func value(for size: CGSize) -> CGFloat {
        let shortSide = min(size.width, size.height)
        guard shortSide > 0 else { return 1 }
        return min(max(shortSide / 393, 0.9), 1.25)
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

extension View {
    /// Pulsante rotondo in vetro con bordo metallico champagne. Se `active`, il vetro si tinge di champagne:
    /// il colore di marca compare solo dove significa "acceso".
    func brandCircle(active: Bool = false) -> some View {
        brandGlass(in: Circle(), active: active)
    }

    func brandGlass<S: InsettableShape>(in shape: S, active: Bool = false, interactive: Bool = true) -> some View {
        modifier(BrandGlass(shape: shape, active: active, interactive: interactive))
    }
}

private struct BrandGlass<S: InsettableShape>: ViewModifier {
    var shape: S
    var active: Bool
    var interactive: Bool

    func body(content: Content) -> some View {
        content
            .glassBackground(in: shape, tint: active ? Brand.champagne.opacity(0.28) : nil, interactive: interactive)
            .overlay {
                shape.strokeBorder(Brand.metal, lineWidth: active ? 1.2 : 0.7)
                    .opacity(active ? 0.95 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

/// Marchio: diaframma e nome inciso, per i momenti in cui l'app si presenta (avvio, permessi).
struct BrandMark: View {
    var apertureSize: CGFloat = 96
    var openness: CGFloat = 0.55

    var body: some View {
        VStack(spacing: 18) {
            ApertureShape(openness: openness)
                .fill(Brand.metal)
                .frame(width: apertureSize, height: apertureSize)
                .shadow(color: Brand.champagne.opacity(0.35), radius: 22)
            Text(Brand.name)
                .font(Brand.mono(15, weight: .bold))
                .tracking(7)
                .foregroundStyle(Brand.metal)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Lumora"))
    }
}

/// Avvio: su nero caldo il diaframma si apre sul nome e poi svanisce nel mirino. Con "Riduci movimento" resta fermo.
struct BrandLaunchOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            BrandMark(apertureSize: 120, openness: open ? 0.9 : 0.15)
                .scaleEffect(open || reduceMotion ? 1 : 0.92)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { open = true }
        }
        .accessibilityHidden(true)
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
