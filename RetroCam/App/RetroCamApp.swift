import SwiftUI
import UIKit

/// Abilita la rotazione dell'interfaccia (verticale e orizzontale) senza toccare le impostazioni del progetto.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}

@main
struct RetroCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Brand.champagne)
        }
    }
}
