import Foundation
import CoreGraphics

/// Adatta il lavoro dell'app alla potenza del dispositivo in cui gira, e alle condizioni del momento
/// (temperatura, risparmio energetico): i telefoni più potenti ottengono un mirino più nitido, quelli
/// più modesti o surriscaldati uno più leggero, così il mirino resta fluido ovunque.
enum DeviceProfile {
    private static let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    /// Larghezza di base del mirino in pixel, secondo la memoria del dispositivo
    /// (8 GB o più: iPhone di fascia alta recenti; 6 GB: fascia media; sotto: modelli più vecchi).
    private static let basePreviewWidth: CGFloat = gigabytes >= 7.5 ? 1280 : (gigabytes >= 5.5 ? 1080 : 960)

    /// Larghezza del mirino adesso: parte dalla base e si riduce se il telefono si scalda o è in risparmio energetico.
    /// Si legge a ogni frame: sono due proprietà di sistema, costo trascurabile.
    static var previewWidth: CGFloat {
        let info = ProcessInfo.processInfo
        switch info.thermalState {
        case .critical: return 480
        case .serious: return min(basePreviewWidth, 640)
        default: break
        }
        return info.isLowPowerModeEnabled ? min(basePreviewWidth, 720) : basePreviewWidth
    }

    /// Risoluzione delle foto se l'utente non ha scelto: 24 MP sui telefoni con molta memoria, altrimenti 12 MP.
    static let defaultMegapixels: Int = gigabytes >= 7.5 ? 24 : 12

    /// Risoluzione chiesta dall'utente (impostazioni dell'app), o quella predefinita. La fotocamera usa la più grande
    /// che il suo sensore offre senza superarla.
    static var photoMegapixels: Int {
        let chosen = UserDefaults.standard.integer(forKey: "photoMegapixels")
        return chosen > 0 ? chosen : defaultMegapixels
    }

    /// Scatti che possono essere in elaborazione insieme: ogni foto filtrata occupa centinaia di MB temporaneamente
    /// (molti di più a 24 e 48 MP), e troppi scatti in coda fanno chiudere l'app per mancanza di memoria.
    static var maxPendingCaptures: Int {
        let base = gigabytes >= 7.5 ? 5 : (gigabytes >= 5.5 ? 4 : 3)
        let penalty = photoMegapixels >= 48 ? 3 : (photoMegapixels >= 24 ? 1 : 0)
        return max(2, base - penalty)
    }
}
