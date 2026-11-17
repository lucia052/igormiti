//
//  RetroCamCapture.swift
//  RetroCamCapture
//
//  Created by Francescopio Manzo on 17/11/2026.
//

import ExtensionKit
import Foundation
import LockedCameraCapture
import SwiftUI

/// Rende RetroCam selezionabile in Impostazioni › Fotocamera › Camera Control (e dalla schermata di blocco).
/// L'estensione non applica i filtri: apre subito l'app, dove c'è il mirino completo.
@main
struct RetroCamCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            RetroCamCaptureViewFinder(session: session)
                .ignoresSafeArea()
                .task {
                    // Con il telefono bloccato il sistema chiede prima di sbloccare
                    let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
                    try? await session.openApplication(for: activity)
                }
        }
    }
}
