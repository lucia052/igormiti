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

    /// Scatti che possono essere in elaborazione insieme: ogni foto filtrata occupa centinaia di MB temporaneamente,
    /// e troppi scatti in coda fanno chiudere l'app per mancanza di memoria.
    static let maxPendingCaptures: Int = gigabytes >= 7.5 ? 5 : (gigabytes >= 5.5 ? 4 : 3)
}
