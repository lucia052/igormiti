import SwiftUI

/// Il frame filtrato. I fotogrammi non passano da SwiftUI: `PreviewModel` li scrive direttamente nel layer della vista
/// sotto, così a 30 fps il thread principale non ricalcola nessuna vista e i tocchi restano pronti.
/// Lo sfondo di riserva compare solo finché non arriva il primo fotogramma.
struct ViewfinderLayer: View {
    @ObservedObject var preview: PreviewModel
    var pixelated: Bool
    var fitsWhole: Bool          // true: l'immagine si vede intera (formati diversi dal 4:3); false: riempie lo schermo

    var body: some View {
        ZStack {
            if !preview.hasImage {
                LinearGradient(colors: [Color(red: 0.9, green: 0.65, blue: 0.44), Color(red: 0.08, green: 0.07, blue: 0.1)],
                               startPoint: .top, endPoint: .bottom)
            }
            FrameLayerView(preview: preview, pixelated: pixelated, fitsWhole: fitsWhole)
        }
    }
}

/// Vista UIKit il cui layer riceve i fotogrammi. Non intercetta i tocchi: restano ai gesti di SwiftUI.
private struct FrameLayerView: UIViewRepresentable {
    let preview: PreviewModel
    var pixelated: Bool
    var fitsWhole: Bool          // true: l'immagine si vede intera (formati diversi dal 4:3); false: riempie lo schermo

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.layer.masksToBounds = true
        preview.layer = view.layer
        view.layer.contents = preview.image          // se un fotogramma c'è già (la vista viene ricreata)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let layer = view.layer
        preview.layer = layer
        // 4:3 riempie lo schermo ritagliando i bordi; gli altri formati (4:5, 9:16, 1:1) si vedono interi, come nella foto
        layer.contentsGravity = fitsWhole ? .resizeAspect : .resizeAspectFill
        layer.magnificationFilter = pixelated ? .nearest : .linear
        layer.minificationFilter = .linear
    }
}

/// Dati di scatto sopra l'otturatore. Osserva solo `HUDModel`: l'aggiornamento non tocca il resto dell'interfaccia.
struct HUDLabel: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        Text(model.text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
    }
}

/// Riquadro di messa a fuoco con cursore dell'esposizione (trascina in verticale dopo il tap).
struct FocusReticle: View {
    var bias: Float
    /// true mentre l'autofocus cerca il fuoco (riquadro bianco che "respira"); false a fuoco bloccato (giallo, fermo)
    var searching = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).stroke(searching ? Color.white : Brand.champagne, lineWidth: searching ? 1 : 1.5)
                .frame(width: 78, height: 78)
                .scaleEffect(searching && breathe ? 1.1 : 1)
                .animation(searching ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true) : .spring(response: 0.25, dampingFraction: 0.55),
                           value: breathe)
                .animation(.easeInOut(duration: 0.2), value: searching)
                .onAppear { breathe = true }
            // Tacche al centro dei lati
            Rectangle().fill(Brand.champagne).frame(width: 1.5, height: 7).offset(y: -36)
            Rectangle().fill(Brand.champagne).frame(width: 1.5, height: 7).offset(y: 36)
            Rectangle().fill(Brand.champagne).frame(width: 7, height: 1.5).offset(x: -36)
            Rectangle().fill(Brand.champagne).frame(width: 7, height: 1.5).offset(x: 36)
            Capsule().fill(Brand.champagne.opacity(0.8))
                .frame(width: 1.5, height: 72)
                .offset(x: 62)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15))
                .foregroundStyle(Brand.champagne)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .offset(x: 62, y: CGFloat(-bias) * 16)
        }
        .frame(width: 170, height: 110)
        .allowsHitTesting(false)
    }
}

/// Griglia dei terzi.
struct GridOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 0.7)
        }
    }
}

/// Schermata mostrata se l'accesso alla fotocamera è stato negato.
struct CameraAccessView: View {
    var body: some View {
        VStack(spacing: 16) {
            BrandMark(apertureSize: 84, openness: 0.3)
                .padding(.bottom, 8)
            Text("Serve l'accesso alla fotocamera")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Lumora usa la fotocamera per mostrare il mirino con i filtri in tempo reale. Puoi attivarla nelle Impostazioni.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Apri Impostazioni")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 24)
                    .frame(height: 48)
            }
            .glassCapsule(interactive: true)
            .padding(.top, 8)
        }
        .padding(32)
    }
}
