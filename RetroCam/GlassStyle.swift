import SwiftUI

/// Liquid Glass nativo (iOS 26 / 27) con fallback a materiale sfocato sui sistemi precedenti.
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            let g: Glass = interactive ? .regular.interactive() : .regular
            self.glassEffect(g, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
    func glassCapsule(interactive: Bool = false) -> some View { glass(in: Capsule(), interactive: interactive) }
    /// Pulsante nativo: vetro di sistema su iOS 26+, altrimenti pulsante "bordered" di sistema.
    @ViewBuilder
    func nativeGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered).tint(.white)
        }
    }
    func glassCircle(interactive: Bool = true) -> some View { glass(in: Circle(), interactive: interactive) }
}

/// Raggruppa più elementi di vetro così si fondono e "morphano" tra loro (iOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
