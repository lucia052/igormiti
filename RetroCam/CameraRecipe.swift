import SwiftUI

// MARK: - Parametri

/// Simulazione del flash diretto: illumina il soggetto, lascia scuro/caldo lo sfondo.
struct FlashParams: Equatable {
    var subjectEV: Float = 0.9          // esposizione extra sul soggetto
    var backgroundEV: Float = -0.8      // sfondo non raggiunto dal flash
    var hotspot: Float = 0.25           // centro del frame più luminoso
    var skinSmoothing: Float = 0        // 0...1, "flash che ammorbidisce la pelle"
    var ambientTop: SIMD3<Float>? = nil     // gradiente ambiente (es. tramonto)
    var ambientBottom: SIMD3<Float>? = nil
    var ambientStrength: Float = 0
}

enum StampOverlay: Equatable { case none, digicamDate, camcorder }
enum FrameStyle: Equatable { case none, instant }

/// Una "ricetta" descrive una fotocamera. Aggiungerne una = aggiungere dati, non codice.
struct CameraRecipe: Identifiable, Equatable {
    let id: String
    var name: String            // nomi neutri: nessun marchio registrato (App Store)
    var subtitle: String
    var symbol: String
    var gradient: [Color]

    // Colore / tono (applicati tramite LUT 3D generata in codice)
    var warmth: Float = 0               // + caldo / - freddo
    var tint: Float = 0                 // + magenta / - verde
    var exposureEV: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var blackLift: Float = 0            // "neri lattiginosi"
    var whitePoint: Float = 1           // < 1 = bianchi non puri
    var highlightRolloff: Float = 0     // 0 = clipping netto, 1 = morbido
    var shadowTint = SIMD3<Float>(0.5, 0.5, 0.5)
    var shadowTintAmount: Float = 0
    var highlightTint = SIMD3<Float>(0.5, 0.5, 0.5)
    var highlightTintAmount: Float = 0

    // Ottica
    var softness: Float = 0             // sfocatura in px (su 1000 px di larghezza)
    var aberration: Float = 0           // aberrazione cromatica laterale (frange R/B ai bordi)
    var bloom: Float = 0
    var bloomRadius: Float = 12
    var halation: Float = 0
    var vignette: Float = 0
    var lightLeak: Float = 0

    // Nastro (VHS)
    var chromaBleed: Float = 0
    var scanlines: Float = 0
    var tracking = false

    // Sensore / elaborazione
    var sharpen: Float = 0              // nitidezza esagerata dei processori economici (aloni sui bordi)
    var grain: Float = 0
    var grainSize: Float = 1
    var grainColor = false
    var dust: Float = 0                 // polvere e graffi sulla pellicola
    var targetWidth: CGFloat? = nil     // risoluzione di lavoro (CCD / VGA)
    var pixelated = false
    var jpegQuality: CGFloat? = nil     // compressione "a blocchi" sulla foto finale

    var flash: FlashParams? = nil
    var overlay: StampOverlay = .none
    var frame: FrameStyle = .none
    var cropSquare = false

    /// Look generato dal modello linguistico a partire da una fotocamera di base.
    var isCustom = false
    var baseID: String? = nil           // fotocamera da cui deriva il look personalizzato

    /// Rapporto mostrato nell'interfaccia.
    var aspectLabel: String { cropSquare ? "1:1" : "4:3" }

    init(id: String, name: String, subtitle: String, symbol: String, gradient: [Color]) {
        self.id = id; self.name = name; self.subtitle = subtitle
        self.symbol = symbol; self.gradient = gradient
    }
}

// MARK: - Le quattro fotocamere

extension CameraRecipe {

    /// Compatta 1": flash ambrato sul soggetto, sfondo scuro tipo tramonto, pelle morbida.
    static let g7x: CameraRecipe = {
        var r = CameraRecipe(id: "g7x", name: "Compatta Flash",
                             subtitle: "Flash ambrato · pelle morbida",
                             symbol: "camera.aperture",
                             gradient: [Color(red: 1, green: 0.54, blue: 0.12), Color(red: 0.48, green: 0.18, blue: 0.07)])
        r.warmth = 0.5; r.tint = 0.06; r.exposureEV = 0.1; r.contrast = 1.1; r.saturation = 1.04
        r.blackLift = 0.025; r.highlightRolloff = 0.3
        r.shadowTint = SIMD3(0.9, 0.38, 0.32); r.shadowTintAmount = 0.16
        r.highlightTint = SIMD3(1.0, 0.86, 0.72); r.highlightTintAmount = 0.08
        r.softness = 0.5; r.aberration = 0.5; r.bloom = 0.3; r.bloomRadius = 14; r.halation = 0.2
        r.vignette = 0.3; r.sharpen = 0.3; r.grain = 0.06; r.grainSize = 1.2
        r.flash = FlashParams(subjectEV: 1.0, backgroundEV: -1.1, hotspot: 0.28, skinSmoothing: 0.45,
                              ambientTop: SIMD3(0.98, 0.55, 0.34), ambientBottom: SIMD3(0.62, 0.24, 0.22),
                              ambientStrength: 0.4)
        return r
    }()

    /// Compatta CCD anni 2000: flash duro, leggermente sovraesposta, bloom, nitidezza esagerata, date stamp.
    static let digicam: CameraRecipe = {
        var r = CameraRecipe(id: "digicam", name: "Digicam 2000",
                             subtitle: "CCD · flash duro · date stamp",
                             symbol: "camera.fill",
                             gradient: [Color(red: 0.49, green: 0.77, blue: 1), Color(red: 0.15, green: 0.31, blue: 0.48)])
        r.warmth = -0.06; r.tint = -0.03; r.exposureEV = 0.3; r.contrast = 1.18; r.saturation = 1.28
        r.blackLift = 0.01; r.highlightRolloff = 0.05
        r.shadowTint = SIMD3(0.2, 0.55, 0.65); r.shadowTintAmount = 0.13
        r.highlightTint = SIMD3(1.0, 0.9, 0.75); r.highlightTintAmount = 0.06
        r.softness = 0.6; r.aberration = 0.9; r.bloom = 0.5; r.bloomRadius = 18; r.vignette = 0.18
        r.sharpen = 0.9
        r.grain = 0.10; r.grainSize = 1.4; r.grainColor = true
        r.targetWidth = 1280; r.jpegQuality = 0.5
        r.flash = FlashParams(subjectEV: 1.2, backgroundEV: -0.7, hotspot: 0.4)
        r.overlay = .digicamDate
        return r
    }()

    /// Istantanea: neri lattiginosi, bianchi caldi, cornice di carta con data a mano, quadrata.
    static let polaroid: CameraRecipe = {
        var r = CameraRecipe(id: "polaroid", name: "Istantanea",
                             subtitle: "Cornice bianca · tinte morbide",
                             symbol: "photo.artframe",
                             gradient: [Color(red: 0.96, green: 0.94, blue: 0.88), Color(red: 0.79, green: 0.73, blue: 0.60)])
        r.warmth = 0.28; r.tint = 0.04; r.exposureEV = 0.12; r.contrast = 0.85; r.saturation = 0.82
        r.blackLift = 0.13; r.whitePoint = 0.93; r.highlightRolloff = 0.55
        r.shadowTint = SIMD3(0.3, 0.6, 0.6); r.shadowTintAmount = 0.1
        r.highlightTint = SIMD3(1.0, 0.9, 0.6); r.highlightTintAmount = 0.12
        r.softness = 1.2; r.aberration = 0.5; r.bloom = 0.35; r.bloomRadius = 16; r.vignette = 0.35
        r.grain = 0.07; r.grainSize = 2.2; r.grainColor = true
        r.lightLeak = 0.2; r.dust = 0.3; r.cropSquare = true; r.frame = .instant
        r.flash = FlashParams(subjectEV: 0.5, backgroundEV: -0.5, hotspot: 0.3)
        return r
    }()

    /// Camcorder VHS: sbavatura del colore, scanline, tracking, neri alzati, mirino REC + data.
    static let handycam: CameraRecipe = {
        var r = CameraRecipe(id: "handycam", name: "Camcorder VHS",
                             subtitle: "REC · tracking · mirino",
                             symbol: "video.fill",
                             gradient: [Color(red: 0.56, green: 0.56, blue: 0.58), Color(red: 0.11, green: 0.11, blue: 0.12)])
        r.warmth = 0.08; r.exposureEV = 0; r.contrast = 0.95; r.saturation = 0.9
        r.blackLift = 0.08; r.highlightRolloff = 0.15
        r.shadowTint = SIMD3(0.3, 0.35, 0.75); r.shadowTintAmount = 0.07
        r.softness = 1.2; r.aberration = 0.4; r.bloom = 0.25; r.vignette = 0.3
        r.grain = 0.14; r.grainSize = 1.6; r.grainColor = true
        r.targetWidth = 720; r.chromaBleed = 0.7; r.scanlines = 0.3; r.tracking = true
        r.overlay = .camcorder
        return r
    }()

    static let all: [CameraRecipe] = [.g7x, .digicam, .polaroid, .handycam]
}
