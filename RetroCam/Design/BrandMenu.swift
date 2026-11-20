import SwiftUI

/// Pannello a tendina nello stile del logo: nero caldo, bordo metallico champagne, ombra morbida.
/// Sostituisce i menu di sistema, che restano grigi e generici sopra il mirino.
struct BrandMenuPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 2) { content() }
            .padding(8)
            .frame(maxWidth: 320)
            .background(Brand.ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Brand.metal, lineWidth: 0.8)
                    .opacity(0.7)
            }
            .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
            .padding(.horizontal, 20)
    }
}

/// Riga di un pannello a tendina. Con `swatch` mostra il colore della fotocamera, altrimenti solo il simbolo.
/// La voce scelta ha lo sfondo champagne e un piccolo diaframma a destra.
struct BrandMenuRow: View {
    var title: Text
    var subtitle: Text? = nil
    var symbol: String
    var swatch: [Color]? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if let swatch {
                        Circle().fill(LinearGradient(colors: swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        Circle().fill(Color.white.opacity(0.08))
                    }
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(swatch == nil ? (selected ? Brand.champagne : Color.white) : Color.white)
                        .shadow(color: .black.opacity(swatch == nil ? 0 : 0.35), radius: 1.5)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(Brand.mono(15, weight: .semibold))
                        .foregroundStyle(selected ? Brand.champagne : Color.white)
                    if let subtitle {
                        subtitle
                            .font(Brand.mono(11, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                if selected {
                    ApertureShape(openness: 0.55)
                        .fill(Brand.metal)
                        .frame(width: 18, height: 18)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.champagne.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
