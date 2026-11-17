import SwiftUI

/// Il frame filtrato. Osserva solo `PreviewModel`: si aggiorna a ogni frame senza toccare il resto della UI.
struct ViewfinderLayer: View {
    @ObservedObject var preview: PreviewModel
    var pixelated: Bool
    var square: Bool

    var body: some View {
        if let cg = preview.image {
            let img = Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .interpolation(pixelated ? .none : .medium)
            if square { img.scaledToFit() } else { img.scaledToFill() }
        } else {
            LinearGradient(colors: [Color(red: 0.9, green: 0.65, blue: 0.44), Color(red: 0.08, green: 0.07, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Riquadro di messa a fuoco con cursore dell'esposizione (trascina in verticale dopo il tap).
struct FocusReticle: View {
    var bias: Float

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 78, height: 78)
            // Tacche al centro dei lati
            Rectangle().fill(Color.yellow).frame(width: 1.5, height: 7).offset(y: -36)
            Rectangle().fill(Color.yellow).frame(width: 1.5, height: 7).offset(y: 36)
            Rectangle().fill(Color.yellow).frame(width: 7, height: 1.5).offset(x: -36)
            Rectangle().fill(Color.yellow).frame(width: 7, height: 1.5).offset(x: 36)
            Capsule().fill(Color.yellow.opacity(0.8))
                .frame(width: 1.5, height: 72)
                .offset(x: 62)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.yellow)
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
            Image(systemName: "camera.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 4)
            Text("Serve l'accesso alla fotocamera")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("RetroCam usa la fotocamera per mostrare il mirino con i filtri in tempo reale. Puoi attivarla nelle Impostazioni.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Apri Impostazioni")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 48)
            }
            .glassCapsule(interactive: true)
            .padding(.top, 8)
        }
        .padding(32)
    }
}
