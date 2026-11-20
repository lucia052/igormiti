import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import ImageIO
import simd

/// preview: mirino. video: fotogrammi registrati (720p). photo: foto finale a piena risoluzione.
enum RenderQuality { case preview, video, photo }

/// Pipeline Core Image a strati. L'ordine segue la fisica della fotocamera:
/// risoluzione → ottica (morbidezza, aberrazione) → processore (nitidezza) → flash → colore (LUT)
/// → bloom/alone → nastro → light leak → vignetta → grana → polvere → overlay → cornice.
final class FilterEngine: @unchecked Sendable {

    let context = CIContext(options: [.cacheIntermediates: false])
    /// Spazio colore di lavoro e di uscita: Display P3 (quello delle foto dell'iPhone). Con sRGB i colori più saturi
    /// venivano tagliati subito all'ingresso della LUT, e le foto uscivano più piatte di quelle originali.
    private let srgb = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)!
    /// Spazio colore di uscita (per chi scrive i fotogrammi fuori dal motore, come il registratore video).
    var outputColorSpace: CGColorSpace { srgb }
    private let lock = NSLock()
    private var cubes: [String: Data] = [:]
    private var stamps: [String: CIImage] = [:]
    private let cubeSize = 32

    private let yearFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yy M d"; return f }()
    private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd MMM yyyy"; return f }()
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private let handFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d.M.yy"; return f }()

    // MARK: - Entry point

    func render(_ source: CIImage, mask personMask: CIImage?, recipe r: CameraRecipe,
                flashOn: Bool, time: Double, quality: RenderQuality) -> CIImage {

        let isPhoto = quality == .photo
        // Nel mirino le variazioni (polvere) cambiano ~2 volte al secondo; nello scatto sono casuali.
        let variation: Double = isPhoto ? Double.random(in: 0..<10_000) : floor(time * 2.5)
        // Il light leak resta fermo nel mirino; ogni scatto ne riceve uno diverso.
        let leakCorner = isPhoto ? Int.random(in: 0..<4) : 0

        var img = source
        // La maschera persona viene portata alle dimensioni della sorgente e poi segue le stesse trasformazioni.
        var matte: CIImage? = personMask.map {
            $0.transformed(by: CGAffineTransform(scaleX: source.extent.width / $0.extent.width,
                                                 y: source.extent.height / $0.extent.height))
        }
        func both(_ f: (CIImage) -> CIImage) { img = f(img); matte = matte.map(f) }

        // 1. Formato (istantanea quadrata, 4:5, 9:16…): ritaglio centrale, che segue l'orientamento dell'immagine
        let aspect: FrameAspect = r.cropSquare ? .square : r.aspect
        do {
            let e = img.extent
            let longSide = max(e.width, e.height), shortSide = min(e.width, e.height)
            var newShort = shortSide, newLong = shortSide / aspect.shortOverLong
            if newLong > longSide { newLong = longSide; newShort = longSide * aspect.shortOverLong }
            let size = e.height >= e.width ? CGSize(width: newShort, height: newLong)
                                           : CGSize(width: newLong, height: newShort)
            if abs(size.width - e.width) > 1 || abs(size.height - e.height) > 1 {
                let rect = CGRect(x: e.midX - size.width / 2, y: e.midY - size.height / 2,
                                  width: size.width, height: size.height).integral
                both { $0.cropped(to: rect) }
            }
        }
        // 2. Risoluzione di lavoro (CCD / VGA / preview veloce)
        // Mirino adattato alla potenza del telefono e alle condizioni del momento (vedi DeviceProfile)
        // La foto resta alla risoluzione scattata (12, 24 o 48 MP): la riducono solo i look "d'epoca" con targetWidth
        // Il video registra con il lato corto scelto nelle impostazioni (720p o 1080p), qualunque sia l'orientamento
        let maxW: CGFloat
        switch quality {
        case .preview: maxW = DeviceProfile.previewWidth
        case .video:
            let short = VideoSettings.shortSide
            maxW = img.extent.width <= img.extent.height ? short : short * img.extent.width / max(img.extent.height, 1)
        case .photo: maxW = .greatestFiniteMagnitude
        }
        let work = min(r.targetWidth ?? maxW, maxW)
        if img.extent.width > work {
            let k = work / img.extent.width
            // Nella foto finale la riduzione (es. 4032 → 1280 / 640) usa Lanczos: niente scalettature.
            // Nel mirino basta l'interpolazione semplice, più leggera a 30 fps.
            both { i in
                guard isPhoto else { return i.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = i; f.scale = Float(k); f.aspectRatio = 1
                return f.outputImage ?? i.transformed(by: CGAffineTransform(scaleX: k, y: k))
            }
        }
        let o = img.extent.origin
        both { $0.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y)) }
        let ext = img.extent
        let s = Float(ext.width / 1000)

        // 3. Ottica: morbidezza e frange cromatiche ai bordi
        if r.softness > 0 { img = blurred(img, sigma: CGFloat(r.softness * s * 1.2)) }
        if r.aberration > 0 { img = aberration(img, amount: r.aberration, ext: ext) }

        // 3b. Processore d'immagine economico: nitidezza esagerata (aloni chiari sui bordi)
        if r.sharpen > 0 { img = sharpen(img, amount: r.sharpen, ext: ext, s: s) }

        // 4. Flash diretto (soggetto vs sfondo)
        if let f = r.flash, flashOn {
            img = applyFlash(img, mask: matte, f: f, ext: ext, s: s)
        }

        // 5. Colore e tono: LUT 3D generata dai parametri
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = img
        cube.cubeDimension = Float(cubeSize)
        cube.cubeData = cubeData(for: r)
        cube.colorSpace = srgb
        img = cube.outputImage ?? img

        // 6. Bloom e alone (halation)
        if r.bloom > 0 {
            let b = CIFilter.bloom()
            b.inputImage = img.clampedToExtent(); b.radius = r.bloomRadius * s; b.intensity = r.bloom
            img = b.outputImage?.cropped(to: ext) ?? img
        }
        if r.halation > 0 { img = halation(img, amount: r.halation, ext: ext, s: s) }

        // 7. Nastro VHS
        if r.chromaBleed > 0 { img = chromaBleed(img, amount: r.chromaBleed, ext: ext, s: s) }
        if r.scanlines > 0   { img = scanlines(img, amount: r.scanlines, ext: ext, s: s) }
        if r.tracking        { img = trackingBand(img, ext: ext, s: s, time: time); img = headSwitching(img, ext: ext, s: s, time: time) }

        // 8. Light leak
        if r.lightLeak > 0 { img = lightLeak(img, amount: r.lightLeak, ext: ext, corner: leakCorner) }

        // 9. Vignettatura
        if r.vignette > 0 {
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: ext.midX, y: ext.midY),
                kCIInputIntensityKey: min(1, r.vignette * 1.2),
                kCIInputRadiusKey: ext.width * 0.85,
                "inputFalloff": 0.5
            ]).cropped(to: ext)
        }

        // 10. Grana
        if r.grain > 0 {
            img = grain(img, amount: r.grain, size: r.grainSize, color: r.grainColor, streaks: r.grainStreaks, ext: ext, s: s)
        }

        // 11. Polvere e graffi (sopra la grana: sono sulla superficie del negativo)
        if r.dust > 0 { img = dust(img, amount: r.dust, ext: ext, s: s, variation: variation) }

        // 12. Overlay (date stamp / mirino camcorder)
        // In 9:16 le storie coprono le fasce in alto e in basso con i loro comandi: data e mirino REC stanno più dentro
        img = overlay(img, kind: r.overlay, time: time, ext: ext, safeY: aspect == .story ? ext.height * 0.12 : 0)

        // 13. Cornice istantanea
        if r.frame == .instant { img = instantFrame(img, ext: ext) }

        // 14. Solo foto finale: compressione JPEG "a blocchi" e pixel nitidi
        if quality == .photo {
            if let q = r.jpegQuality,
               let data = context.jpegRepresentation(of: img, colorSpace: srgb,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): q]),
               let degraded = CIImage(data: data) {
                img = degraded
            }
            if r.pixelated {
                img = img.samplingNearest().transformed(by: CGAffineTransform(scaleX: 3, y: 3))
            }
        }
        return img
    }

    // MARK: - Flash

    private func applyFlash(_ img: CIImage, mask: CIImage?, f: FlashParams, ext: CGRect, s: Float) -> CIImage {
        // Peso radiale: centro = 1, bordi = 0 (il flash cala con la distanza)
        let radial = CIFilter.radialGradient()
        radial.center = CGPoint(x: ext.midX, y: ext.midY + ext.height * 0.05)
        radial.radius0 = Float(ext.width * 0.12)
        radial.radius1 = Float(max(ext.width, ext.height) * 0.7)
        radial.color0 = CIColor.white; radial.color1 = CIColor.black
        let weight = radial.outputImage!.cropped(to: ext)

        // Soggetto: più luce, hotspot centrale, pelle ammorbidita
        var subject = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: f.subjectEV])
        if f.hotspot > 0 {
            // La somma raddoppia anche l'alfa (1+1): va riportato a 1, altrimenti i filtri successivi dimezzano i colori
            subject = scaleRGB(weight, SIMD3(repeating: f.hotspot * 0.35))
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: subject])
                .settingAlphaOne(in: ext)
        }
        if f.skinSmoothing > 0 {
            let soft = blurred(subject, sigma: CGFloat(3 * s))
            subject = subject.applyingFilter("CIDissolveTransition",
                parameters: [kCIInputTargetImageKey: soft, kCIInputTimeKey: f.skinSmoothing])
        }

        // Sfondo: non raggiunto dal flash, domina la luce ambiente (ambra / tramonto)
        var bg = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: f.backgroundEV])
        if let top = f.ambientTop, let bottom = f.ambientBottom, f.ambientStrength > 0 {
            let grad = CIFilter.linearGradient()
            grad.point0 = CGPoint(x: 0, y: ext.maxY); grad.point1 = CGPoint(x: 0, y: ext.minY)
            grad.color0 = CIColor(red: CGFloat(top.x), green: CGFloat(top.y), blue: CGFloat(top.z))
            grad.color1 = CIColor(red: CGFloat(bottom.x), green: CGFloat(bottom.y), blue: CGFloat(bottom.z))
            let tinted = grad.outputImage!.cropped(to: ext)
                .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: bg])
            bg = bg.applyingFilter("CIDissolveTransition",
                parameters: [kCIInputTargetImageKey: tinted, kCIInputTimeKey: f.ambientStrength])
        }

        // Maschera: persona (Vision) con bordo sfumato; se manca, vale il peso radiale
        let m = mask.map { blurred($0, sigma: CGFloat(4 * s)) } ?? weight
        return subject.applyingFilter("CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m])
    }

    // MARK: - Ottica

    /// Aberrazione cromatica laterale: il rosso ingrandisce, il blu rimpicciolisce, rispetto al centro.
    /// Invisibile al centro, frange colorate verso i bordi, come nelle lenti economiche.
    private func aberration(_ img: CIImage, amount: Float, ext: CGRect) -> CIImage {
        let k = CGFloat(amount) * 0.004
        let c = CGPoint(x: ext.midX, y: ext.midY)
        func chan(_ v: SIMD3<Float>, _ scale: CGFloat) -> CIImage {
            let t = CGAffineTransform(translationX: c.x, y: c.y)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -c.x, y: -c.y)
            return scaleRGB(img, v).clampedToExtent().transformed(by: t)
        }
        return chan(SIMD3(1, 0, 0), 1 + k)
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: chan(SIMD3(0, 1, 0), 1)])
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: chan(SIMD3(0, 0, 1), 1 - k)])
            .cropped(to: ext)
    }

    /// Unsharp mask aggressivo: i bordi ricevono l'alone chiaro tipico delle compatte e dei telefoni di inizio 2000.
    private func sharpen(_ img: CIImage, amount: Float, ext: CGRect, s: Float) -> CIImage {
        img.clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: Double(max(0.9, 1.6 * s)),
                kCIInputIntensityKey: Double(amount * 1.4)])
            .cropped(to: ext)
    }

    // MARK: - Effetti

    private func halation(_ img: CIImage, amount: Float, ext: CGRect, s: Float) -> CIImage {
        // Estrae le alte luci, le sfoca a due raggi, le tinge di arancio/rosso e le aggiunge (screen)
        let hi = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0),
            "inputBiasVector": CIVector(x: -1.7, y: -1.7, z: -1.7, w: 0)
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        // Alone stretto e caldo + alone largo e rosso: il primo dà il bagliore, il secondo l'atmosfera
        let tight = scaleRGB(blurred(hi, sigma: CGFloat(7 * s)), SIMD3<Float>(1.0, 0.55, 0.28) * (amount * 0.7))
        let wide = scaleRGB(blurred(hi, sigma: CGFloat(22 * s)), SIMD3<Float>(1.0, 0.32, 0.14) * amount)
        return wide.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: tight])
            .cropped(to: ext)
    }

    /// Perdita di luce: tre chiazze sovrapposte (arancio, giallo, magenta) da un angolo, diverse a ogni scatto.
    private func lightLeak(_ img: CIImage, amount: Float, ext: CGRect, corner: Int) -> CIImage {
        let a = CGFloat(amount)
        let anchors: [CGPoint] = [
            CGPoint(x: ext.maxX, y: ext.maxY * 0.95),
            CGPoint(x: ext.minX, y: ext.maxY * 0.12),
            CGPoint(x: ext.maxX, y: ext.maxY * 0.10),
            CGPoint(x: ext.minX, y: ext.maxY * 0.90)
        ]
        let c = anchors[corner % anchors.count]
        let inward: CGFloat = c.x > ext.midX ? -1 : 1
        var out = img

        func blob(_ center: CGPoint, _ radius: CGFloat, _ c0: CIColor, _ c1: CIColor) {
            let g = CIFilter.radialGradient()
            g.center = center; g.radius0 = 0; g.radius1 = Float(radius)
            g.color0 = c0; g.color1 = c1
            if let leak = g.outputImage?.cropped(to: ext) {
                out = leak.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out])
            }
        }
        blob(c, ext.width * 0.95,
             CIColor(red: 1, green: 0.42, blue: 0.08, alpha: a),
             CIColor(red: 1, green: 0.15, blue: 0, alpha: 0))
        blob(CGPoint(x: c.x + inward * ext.width * 0.20, y: c.y), ext.width * 0.55,
             CIColor(red: 1, green: 0.85, blue: 0.25, alpha: a * 0.7),
             CIColor(red: 1, green: 0.7, blue: 0.1, alpha: 0))
        blob(CGPoint(x: c.x + inward * ext.width * 0.45, y: c.y + (c.y > ext.midY ? -1 : 1) * ext.height * 0.12),
             ext.width * 0.38,
             CIColor(red: 0.9, green: 0.1, blue: 0.4, alpha: a * 0.5),
             CIColor(red: 0.9, green: 0.1, blue: 0.4, alpha: 0))
        return out
    }

    /// Polvere (puntini chiari, morbidi) e, ogni tanto, un graffio verticale sottile.
    private func dust(_ img: CIImage, amount: Float, ext: CGRect, s: Float, variation: Double) -> CIImage {
        var out = img
        if let noise = CIFilter.randomGenerator().outputImage {
            let p = CGFloat(min(0.02, 0.006 * amount))          // probabilità di un puntino per pixel
            let k = 3 / p
            let scale = CGFloat(max(1.4, 2.0 * s))
            let dx = CGFloat((variation * 131).truncatingRemainder(dividingBy: 997).rounded())
            let dy = CGFloat((variation * 71).truncatingRemainder(dividingBy: 991).rounded())
            let specks = noise
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: ext).settingAlphaOne(in: ext)      // alfa del rumore casuale → opaco
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -k * (1 - p), y: -k * (1 - p), z: -k * (1 - p), w: 1)
                ])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                .cropped(to: ext)
            let soft = scaleRGB(blurred(specks, sigma: CGFloat(0.55 * s)), SIMD3<Float>(1.0, 0.97, 0.92) * Float(2.2))
            out = soft.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out])
        }
        if amount > 0.3, Int(variation) % 4 == 0 {
            let fx = CGFloat((Int(variation) * 7919) % 1000) / 1000
            let rect = CGRect(x: ext.minX + ext.width * fx, y: ext.minY,
                              width: max(1, 0.9 * CGFloat(s)), height: ext.height)
            let line = CIImage(color: CIColor(red: 1, green: 0.98, blue: 0.94, alpha: CGFloat(0.12 * amount)))
                .cropped(to: rect)
            out = line.composited(over: out)
        }
        return out
    }

    private func chromaBleed(_ img: CIImage, amount: Float, ext: CGRect, s: Float) -> CIImage {
        // Il colore VHS ha meno banda della luminanza: si spalma in orizzontale
        let smear = img.clampedToExtent().applyingFilter("CIMotionBlur",
            parameters: [kCIInputRadiusKey: Double(18 * amount * s), kCIInputAngleKey: 0.0]).cropped(to: ext)
        let mixed = img.applyingFilter("CIDissolveTransition",
            parameters: [kCIInputTargetImageKey: smear, kCIInputTimeKey: min(0.75, amount)])
        // Aberrazione: R a sinistra, B a destra (screen = somma, perché i canali sono disgiunti)
        let dx = CGFloat(2.5 * s)
        func chan(_ v: SIMD3<Float>, _ shift: CGFloat) -> CIImage {
            scaleRGB(mixed, v).clampedToExtent().transformed(by: CGAffineTransform(translationX: shift, y: 0))
        }
        return chan(SIMD3(1, 0, 0), -dx)
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: chan(SIMD3(0, 1, 0), 0)])
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: chan(SIMD3(0, 0, 1), dx)])
            .cropped(to: ext)
    }

    private func scanlines(_ img: CIImage, amount: Float, ext: CGRect, s: Float) -> CIImage {
        let st = CIFilter.stripesGenerator()
        st.center = .zero; st.width = max(1.5, 2 * s); st.sharpness = 1
        st.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(amount))
        st.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let lines = st.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: ext)
        else { return img }
        return lines.composited(over: img)
    }

    private func trackingBand(_ img: CIImage, ext: CGRect, s: Float, time: Double) -> CIImage {
        let phase = CGFloat((time * 0.18).truncatingRemainder(dividingBy: 1))
        let h = ext.height * 0.05
        let rect = CGRect(x: ext.minX, y: ext.minY + (ext.height - h) * (1 - phase), width: ext.width, height: h)
        let dx = CGFloat(8 * s) * CGFloat(sin(time * 40))
        let band = img.clampedToExtent().cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.12, kCIInputSaturationKey: 0.7])
            .cropped(to: rect)
        return band.composited(over: img)
    }

    /// Rumore di commutazione delle testine: la striscia irregolare in fondo al fotogramma, tipica del nastro.
    private func headSwitching(_ img: CIImage, ext: CGRect, s: Float, time: Double) -> CIImage {
        let h = ext.height * 0.025
        let rect = CGRect(x: ext.minX, y: ext.minY, width: ext.width, height: h)
        // Strappo laterale che cambia a ogni istante, più forte verso il bordo inferiore
        let dx = CGFloat(10 * s) * CGFloat(sin(time * 23) + 0.5 * sin(time * 61))
        let strip = img.clampedToExtent().cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.06, kCIInputSaturationKey: 0.5])
            .cropped(to: rect)
        return strip.composited(over: img)
    }

    private func grain(_ img: CIImage, amount: Float, size: Float, color: Bool, streaks: Bool, ext: CGRect, s: Float) -> CIImage {
        guard var noise = CIFilter.randomGenerator().outputImage else { return img }
        // La grana cresce con la risoluzione (s = larghezza/1000): la foto a piena risoluzione ha la stessa grana
        // vista nel mirino, invece di una polvere impercettibile.
        let grainSize = CGFloat(max(size, 1)) * CGFloat(max(s, 1))
        // Nastro: il rumore si allunga in orizzontale (strisce), non è tondo come la grana della pellicola
        let sx = grainSize * (streaks ? 5 : 1), sy = grainSize
        if sx > 1 || sy > 1 { noise = noise.transformed(by: CGAffineTransform(scaleX: sx, y: sy)) }
        noise = noise.transformed(by: CGAffineTransform(translationX: .random(in: 0...512), y: .random(in: 0...512)))
        // Il rumore ha anche l'alfa casuale: va reso opaco prima dei filtri di colore, che altrimenti lo "dividono"
        noise = noise.cropped(to: ext).settingAlphaOne(in: ext)
        // I grani grossi si sfocano appena: la pellicola vera ha "grumi", non pixel casuali
        let clumpy = size > 1.6
        let a = CGFloat(min(1, amount * 2.5 * (clumpy ? 1.35 : 1)))
        let bias = CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 1)
        let params: [String: Any] = color
            ? ["inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
               "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
               "inputBiasVector": bias]
            : ["inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
               "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
               "inputBiasVector": bias]
        var layer = noise.applyingFilter("CIColorMatrix", parameters: params).cropped(to: ext)
        if clumpy { layer = blurred(layer, sigma: 0.5) }
        return layer.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
    }

    // MARK: - Overlay & cornice

    private func overlay(_ img: CIImage, kind: StampOverlay, time: Double, ext: CGRect, safeY: CGFloat = 0) -> CIImage {
        switch kind {
        case .none:
            return img
        case .digicamDate:
            let text = "’" + yearFmt.string(from: Date())
            let st = stamp(text, color: UIColor(red: 1, green: 0.55, blue: 0.12, alpha: 1), size: ext.width * 0.05, glow: .orange)
            return place(st, in: ext, right: true, top: false, margin: ext.width * 0.03, over: img, extraY: safeY)
        case .instantDate:
            // Data arancione impressa nella foto, in basso a sinistra (la cornice viene aggiunta dopo)
            let text = "’" + yearFmt.string(from: Date())
            let st = stamp(text, color: UIColor(red: 1, green: 0.55, blue: 0.12, alpha: 1), size: ext.width * 0.045, glow: .orange)
            return place(st, in: ext, right: false, top: false, margin: ext.width * 0.03, over: img, extraY: safeY)
        case .camcorder:
            let size = ext.width * 0.045
            let blink = Int(time * 1.5) % 2 == 0
            var out = brackets(img, ext: ext)
            out = place(stamp(blink ? "● REC" : "  REC", color: .red, size: size, glow: nil),
                        in: ext, right: false, top: true, margin: ext.width * 0.03, over: out, extraY: safeY)
            out = place(stamp("SP ■■■", color: .white, size: size * 0.8, glow: nil),
                        in: ext, right: true, top: true, margin: ext.width * 0.03, over: out, extraY: safeY)
            out = place(stamp(dayFmt.string(from: Date()).uppercased(), color: .white, size: size * 0.85, glow: nil),
                        in: ext, right: false, top: false, margin: ext.width * 0.03, over: out, extraY: safeY)
            out = place(stamp(timeFmt.string(from: Date()), color: .white, size: size * 0.85, glow: nil),
                        in: ext, right: true, top: false, margin: ext.width * 0.03, over: out, extraY: safeY)
            return out
        }
    }

    /// Quattro angoli del mirino di una videocamera.
    private func brackets(_ img: CIImage, ext: CGRect) -> CIImage {
        let t = max(2, ext.width * 0.004), l = ext.width * 0.07
        let mx = ext.width * 0.08, my = ext.width * 0.13
        let x0 = ext.minX + mx, x1 = ext.maxX - mx
        let y0 = ext.minY + my, y1 = ext.maxY - my
        let rects: [CGRect] = [
            CGRect(x: x0, y: y1 - t, width: l, height: t), CGRect(x: x0, y: y1 - l, width: t, height: l),
            CGRect(x: x1 - l, y: y1 - t, width: l, height: t), CGRect(x: x1 - t, y: y1 - l, width: t, height: l),
            CGRect(x: x0, y: y0, width: l, height: t), CGRect(x: x0, y: y0, width: t, height: l),
            CGRect(x: x1 - l, y: y0, width: l, height: t), CGRect(x: x1 - t, y: y0, width: t, height: l)
        ]
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        var out = img
        for r in rects { out = white.cropped(to: r).composited(over: out) }
        return out
    }

    private func stamp(_ text: String, color: UIColor, size: CGFloat, glow: UIColor?, hand: Bool = false) -> CIImage {
        let key = "\(text)|\(Int(size))|\(color.hashValue)|\(hand)"
        lock.lock()
        if let c = stamps[key] { lock.unlock(); return c }
        lock.unlock()

        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if hand {
            attrs[.font] = UIFont(name: "Noteworthy-Light", size: size) ?? UIFont.italicSystemFont(ofSize: size)
        } else {
            let shadow = NSShadow()
            shadow.shadowColor = (glow ?? .black).withAlphaComponent(0.9)
            shadow.shadowBlurRadius = size * 0.25; shadow.shadowOffset = .zero
            attrs[.font] = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
            attrs[.shadow] = shadow
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let pad = size * 0.4, sz = str.size()
        let canvas = CGSize(width: ceil(sz.width + pad * 2), height: ceil(sz.height + pad * 2))
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let ui = UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in str.draw(at: CGPoint(x: pad, y: pad)) }
        let ci = CIImage(image: ui) ?? CIImage.empty()

        lock.lock()
        if stamps.count > 40 { stamps.removeAll() }
        stamps[key] = ci
        lock.unlock()
        return ci
    }

    private func place(_ st: CIImage, in ext: CGRect, right: Bool, top: Bool, margin: CGFloat, over img: CIImage,
                       extraY: CGFloat = 0) -> CIImage {
        let x = right ? ext.maxX - st.extent.width - margin * 0.3 : ext.minX + margin * 0.3
        let y = top ? ext.maxY - st.extent.height - margin * 1.2 - extraY : ext.minY + margin * 0.5 + extraY
        return st.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: img)
    }

    /// Cornice di carta: grana della carta, sottile ombra attorno alla foto e data scritta a mano nel bordo largo.
    private func instantFrame(_ img: CIImage, ext: CGRect) -> CIImage {
        let w = ext.width, border = w * 0.035, bottom = w * 0.11
        let canvas = CGRect(x: 0, y: 0, width: w + 2 * border, height: ext.height + border + bottom)
        var paper = CIImage(color: CIColor(red: 0.96, green: 0.945, blue: 0.91)).cropped(to: canvas)

        if let n = CIFilter.randomGenerator().outputImage {
            let a: CGFloat = 0.05
            let tex = n.transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.6))
                .cropped(to: canvas).settingAlphaOne(in: canvas)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 1)])
                .cropped(to: canvas)
            paper = tex.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: paper])
        }

        let photo = CGRect(x: border, y: bottom, width: w, height: ext.height)
        let t = max(1, w * 0.002)
        let edge = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.22))
            .cropped(to: photo.insetBy(dx: -t, dy: -t))
        paper = edge.composited(over: paper)

        return img.transformed(by: CGAffineTransform(translationX: border - ext.minX, y: bottom - ext.minY))
            .composited(over: paper)
    }

    // MARK: - Helper

    private func blurred(_ i: CIImage, sigma: CGFloat) -> CIImage {
        i.clampedToExtent().applyingGaussianBlur(sigma: Double(max(0.01, sigma))).cropped(to: i.extent)
    }

    private func scaleRGB(_ i: CIImage, _ v: SIMD3<Float>) -> CIImage {
        i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(v.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(v.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(v.z), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    // MARK: - LUT 3D procedurale

    /// Prepara in anticipo le LUT delle fotocamere (da una coda in background): il primo cambio di look non blocca il mirino.
    func prewarm(_ recipes: [CameraRecipe]) {
        for r in recipes { _ = cubeData(for: r) }
    }

    private func cubeData(for r: CameraRecipe) -> Data {
        lock.lock()
        if let d = cubes[r.id] { lock.unlock(); return d }
        lock.unlock()
        // Il calcolo (32³ colori) avviene fuori dal lock: mirino e scatto non si bloccano a vicenda
        let d = buildCube(for: r)
        lock.lock()
        // I look personalizzati hanno un id nuovo a ogni generazione: limita la cache (~0,5 MB a LUT)
        if cubes.count >= 8 { cubes.removeAll() }
        cubes[r.id] = d
        lock.unlock()
        return d
    }

    private func buildCube(for r: CameraRecipe) -> Data {
        let n = cubeSize
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for rr in 0..<n {      // rosso varia più in fretta (ordine richiesto da CIColorCube)
            let c = SIMD3<Float>(Float(rr), Float(g), Float(b)) / Float(n - 1)
            let o = tone(c, r)
            data[i] = o.x; data[i + 1] = o.y; data[i + 2] = o.z; data[i + 3] = 1
            i += 4
        } } }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func roll(_ x: Float, _ knee: Float) -> Float {
        x <= knee ? x : knee + (1 - knee) * tanh((x - knee) / (1 - knee))
    }

    private func contrastCurve(_ x: Float, _ k: Float) -> Float {
        if k <= 1 { return (x - 0.5) * k + 0.5 }
        let v = min(max(x, 0), 1)
        let smooth = v * v * (3 - 2 * v)
        return v + (smooth - v) * min(1, (k - 1) * 2.5)
    }

    /// Calcolo per singolo canale con soli Float: evita operatori SIMD ambigui e lento type-checking.
    private func tone(_ c0: SIMD3<Float>, _ r: CameraRecipe) -> SIMD3<Float> {
        // Esposizione e bilanciamento del bianco in lineare
        let exposure: Float = exp2(r.exposureEV)
        let gainR: Float = 1 + 0.30 * r.warmth
        let gainG: Float = 1 - 0.10 * r.tint + 0.02 * r.warmth
        let gainB: Float = 1 - 0.38 * r.warmth

        var red: Float = powf(c0.x, 2.2) * exposure * gainR
        var green: Float = powf(c0.y, 2.2) * exposure * gainG
        var blue: Float = powf(c0.z, 2.2) * exposure * gainB
        red = powf(max(red, 0), 1 / 2.2)
        green = powf(max(green, 0), 1 / 2.2)
        blue = powf(max(blue, 0), 1 / 2.2)

        // Roll-off delle alte luci (0 = clipping netto stile compatta, 1 = morbido)
        if r.highlightRolloff > 0 {
            let knee: Float = 1 - 0.5 * r.highlightRolloff
            red = roll(red, knee)
            green = roll(green, knee)
            blue = roll(blue, knee)
        }

        // Contrasto: curva a S morbida sopra 1 (niente clipping brusco), lineare sotto 1
        let contrast: Float = r.contrast
        red = contrastCurve(red, contrast)
        green = contrastCurve(green, contrast)
        blue = contrastCurve(blue, contrast)

        // Saturazione
        let l0: Float = luma(red, green, blue)
        let sat: Float = r.saturation
        red = l0 + (red - l0) * sat
        green = l0 + (green - l0) * sat
        blue = l0 + (blue - l0) * sat

        // Split toning (preserva la luminanza)
        let lum: Float = min(max(luma(red, green, blue), 0), 1)
        let shadowW: Float = r.shadowTintAmount * (1 - lum) * (1 - lum)
        let highlightW: Float = r.highlightTintAmount * lum * lum
        let sLuma: Float = luma(r.shadowTint.x, r.shadowTint.y, r.shadowTint.z)
        let hLuma: Float = luma(r.highlightTint.x, r.highlightTint.y, r.highlightTint.z)

        let sR: Float = (r.shadowTint.x - sLuma) * shadowW
        let sG: Float = (r.shadowTint.y - sLuma) * shadowW
        let sB: Float = (r.shadowTint.z - sLuma) * shadowW
        let hR: Float = (r.highlightTint.x - hLuma) * highlightW
        let hG: Float = (r.highlightTint.y - hLuma) * highlightW
        let hB: Float = (r.highlightTint.z - hLuma) * highlightW
        red += sR + hR
        green += sG + hG
        blue += sB + hB

        // Neri alzati / bianco non puro
        let lift: Float = r.blackLift
        let range: Float = r.whitePoint - r.blackLift
        red = lift + red * range
        green = lift + green * range
        blue = lift + blue * range

        return SIMD3<Float>(clamp01(red), clamp01(green), clamp01(blue))
    }

    private func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
}
