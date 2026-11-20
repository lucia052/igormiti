import Foundation
import CoreGraphics

/// Impostazioni del video retrò, scelte nelle impostazioni dell'app.
enum VideoSettings {
    /// Lato corto del filmato in pixel: 720 (720p) o 1080 (1080p). I look "d'epoca" con una loro risoluzione
    /// (Nastro a 640) restano più piccoli.
    static var shortSide: CGFloat {
        UserDefaults.standard.integer(forKey: "videoResolution") == 1080 ? 1080 : 720
    }

    /// Fotogrammi al secondo: 24 (effetto cinema) o 30.
    static var frameRate: Int {
        UserDefaults.standard.integer(forKey: "videoFrameRate") == 24 ? 24 : 30
    }

    /// Registrare l'audio del microfono (predefinito: sì).
    static var recordsAudio: Bool {
        UserDefaults.standard.object(forKey: "videoAudio") as? Bool ?? true
    }
}
