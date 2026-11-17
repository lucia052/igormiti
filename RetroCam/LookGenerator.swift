import Foundation
import SwiftUI
import FoundationModels

// MARK: - Output strutturato del modello

/// Colori ammessi per le dominanti: il modello sceglie un nome, i valori RGB li decidiamo noi.
@available(iOS 26.0, *)
@Generable
enum LookTint {
    case neutral, orange, red, pink, magenta, blue, teal, green, yellow

    var rgb: SIMD3<Float> {
        switch self {
        case .neutral: return SIMD3(0.5, 0.5, 0.5)
        case .orange:  return SIMD3(0.95, 0.5, 0.25)
        case .red:     return SIMD3(0.9, 0.25, 0.25)
        case .pink:    return SIMD3(1.0, 0.6, 0.8)
        case .magenta: return SIMD3(0.8, 0.2, 0.6)
        case .blue:    return SIMD3(0.25, 0.4, 0.9)
        case .teal:    return SIMD3(0.2, 0.6, 0.65)
        case .green:   return SIMD3(0.3, 0.7, 0.4)
        case .yellow:  return SIMD3(1.0, 0.85, 0.4)
        }
    }
}

/// Parametri di colore e ottica che il modello può regolare. Gli intervalli proteggono
/// da valori che rovinerebbero l'immagine; il resto della ricetta (flash, cornice, overlay) resta della fotocamera di base.
@available(iOS 26.0, *)
@Generable
struct LookAdjustment {
    @Guide(description: "Nome breve del look, da una a tre parole, in italiano")
    var title: String

    @Guide(description: "Temperatura colore: negativo = freddo/bluastro, positivo = caldo/arancio", .range(-0.8...0.8))
    var warmth: Double
    @Guide(description: "Tinta: negativo = verdastro, positivo = magenta", .range(-0.3...0.3))
    var tint: Double
    @Guide(description: "Esposizione in stop: negativo = più scuro", .range(-0.8...0.8))
    var exposure: Double
    @Guide(description: "Contrasto, 1 = neutro", .range(0.75...1.35))
    var contrast: Double
    @Guide(description: "Saturazione, 1 = neutra, sotto 1 = più spenta", .range(0.5...1.5))
    var saturation: Double
    @Guide(description: "Neri alzati (effetto sbiadito/lattiginoso), 0 = neri profondi", .range(0...0.2))
    var blackLift: Double

    @Guide(description: "Colore dominante nelle ombre")
    var shadowTint: LookTint
    @Guide(description: "Intensità della dominante nelle ombre", .range(0...0.25))
    var shadowTintAmount: Double
    @Guide(description: "Colore dominante nelle alte luci")
    var highlightTint: LookTint
    @Guide(description: "Intensità della dominante nelle alte luci", .range(0...0.2))
    var highlightTintAmount: Double

    @Guide(description: "Grana della pellicola, 0 = nessuna", .range(0...0.3))
    var grain: Double
    @Guide(description: "Vignettatura ai bordi, 0 = nessuna", .range(0...0.7))
    var vignette: Double
    @Guide(description: "Bagliore morbido sulle luci, 0 = nessuno", .range(0...0.7))
    var bloom: Double
    @Guide(description: "Morbidezza dell'obiettivo, 0 = nitido", .range(0...1.8))
    var softness: Double
    @Guide(description: "Perdite di luce arancio sui bordi, 0 = nessuna", .range(0...0.4))
    var lightLeak: Double
}

// MARK: - Generatore

enum LookGenerator {

    enum LookError: LocalizedError {
        case unavailable(String)
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .failed: return "Non sono riuscito a creare il look. Riprova con una descrizione diversa."
            }
        }
    }

    /// `nil` se il modello è pronto, altrimenti il motivo da mostrare all'utente.
    static var unavailableReason: String? {
        guard #available(iOS 26.0, *) else {
            return "Serve iOS 26 o successivo con Apple Intelligence."
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Questo dispositivo non supporta Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Attiva Apple Intelligence in Impostazioni per creare look con l'AI."
            case .modelNotReady:
                return "Il modello AI si sta ancora scaricando. Riprova tra poco."
            @unknown default:
                return "Il modello AI non è disponibile."
            }
        }
    }

    /// Crea una ricetta personalizzata: i parametri di colore e ottica vengono dal modello,
    /// flash, cornice, overlay e risoluzione restano quelli della fotocamera di base.
    static func generate(prompt: String, base: CameraRecipe) async throws -> CameraRecipe {
        if let reason = unavailableReason { throw LookError.unavailable(reason) }
        guard #available(iOS 26.0, *) else { throw LookError.failed }

        let session = LanguageModelSession(instructions: """
            Sei un colorist esperto di fotografia analogica e di fotocamere compatte vintage. \
            L'utente descrive un look in poche parole. Traducilo in parametri di colore e ottica \
            coerenti con la descrizione, restando entro valori realistici: evita impostazioni estreme \
            su più parametri contemporaneamente. Il nome del look deve essere in italiano.
            """)
        let response = try await session.respond(
            to: "Fotocamera di partenza: \(base.name). Look richiesto: \(prompt)",
            generating: LookAdjustment.self)
        return apply(response.content, to: base, prompt: prompt)
    }

    @available(iOS 26.0, *)
    private static func apply(_ a: LookAdjustment, to base: CameraRecipe, prompt: String) -> CameraRecipe {
        // Id nuovo a ogni look: la LUT 3D è in cache per id, quindi deve cambiare con i parametri
        var r = CameraRecipe(id: "custom-\(UUID().uuidString.prefix(8))",
                         name: String(a.title.prefix(24)), subtitle: prompt,
                         symbol: "sparkles", gradient: base.gradient)
        r.isCustom = true
        r.baseID = base.baseID ?? base.id

        // Struttura della fotocamera di base
        r.flash = base.flash; r.overlay = base.overlay; r.frame = base.frame; r.cropSquare = base.cropSquare
        r.targetWidth = base.targetWidth; r.pixelated = base.pixelated; r.jpegQuality = base.jpegQuality
        r.chromaBleed = base.chromaBleed; r.scanlines = base.scanlines; r.tracking = base.tracking
        r.aberration = base.aberration; r.sharpen = base.sharpen; r.bloomRadius = base.bloomRadius
        r.grainSize = base.grainSize; r.grainColor = base.grainColor
        r.whitePoint = base.whitePoint; r.highlightRolloff = base.highlightRolloff
        r.halation = base.halation; r.dust = base.dust

        // Parametri decisi dal modello (riportati comunque negli intervalli sicuri)
        r.warmth = clamp(a.warmth, -0.8, 0.8)
        r.tint = clamp(a.tint, -0.3, 0.3)
        r.exposureEV = clamp(a.exposure, -0.8, 0.8)
        r.contrast = clamp(a.contrast, 0.75, 1.35)
        r.saturation = clamp(a.saturation, 0.5, 1.5)
        r.blackLift = clamp(a.blackLift, 0, 0.2)
        r.shadowTint = a.shadowTint.rgb
        r.shadowTintAmount = a.shadowTint == .neutral ? 0 : clamp(a.shadowTintAmount, 0, 0.25)
        r.highlightTint = a.highlightTint.rgb
        r.highlightTintAmount = a.highlightTint == .neutral ? 0 : clamp(a.highlightTintAmount, 0, 0.2)
        r.grain = clamp(a.grain, 0, 0.3)
        r.vignette = clamp(a.vignette, 0, 0.7)
        r.bloom = clamp(a.bloom, 0, 0.7)
        r.softness = clamp(a.softness, 0, 1.8)
        r.lightLeak = clamp(a.lightLeak, 0, 0.4)
        return r
    }

    private static func clamp(_ v: Double, _ lo: Float, _ hi: Float) -> Float {
        min(hi, max(lo, Float(v)))
    }
}
