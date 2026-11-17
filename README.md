# RetroCam

App iPhone (SwiftUI, iOS 17+, Liquid Glass su iOS 26+) con sei fotocamere retrò in tempo reale: mirino filtrato, flash simulato con maschera persona, ghiera di messa a fuoco manuale, aptica.

## Come aprirla
1. Apri `RetroCam.xcodeproj` con Xcode 26 o successivo.
2. In *Signing & Capabilities* scegli il tuo Team (il bundle ID attuale è `Flavia.progetto1`).
3. Collega un iPhone vero e premi Run. Nel simulatore la fotocamera non esiste: vedrai solo il gradiente di riserva.

Se hai già un progetto funzionante, basta sostituire la cartella `RetroCam/` (il gruppo è sincronizzato: i file nuovi vengono inclusi da soli) e, per i testi dei permessi in italiano, copiare le righe `INFOPLIST_KEY_*` da `project.pbxproj`.

## Impostazioni di build importanti
- `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` e `SWIFT_VERSION = 5.0`: già impostati. Servono perché `CameraManager` lavora su code AVFoundation, non sul main actor.

## Struttura
| File | Ruolo |
|---|---|
| `CameraRecipe.swift` | Dati delle sei fotocamere. Aggiungerne una = aggiungere una ricetta a `all`. |
| `FilterEngine.swift` | Pipeline Core Image: ottica, flash, LUT 3D, bloom, nastro, leak, grana, polvere, overlay, cornice. |
| `CameraManager.swift` | Sessione AVFoundation, front/back, zoom, esposizione, fuoco, salvataggio. |
| `ContentView.swift` | Interfaccia: mirino, gesti, barre in vetro, timer, toast. |
| `ViewfinderComponents.swift` | Mirino, riquadro di fuoco, griglia, schermata permessi. |
| `FocusRingView.swift` | Ghiera di messa a fuoco manuale. |
| `CameraPickerSheet.swift` | Scelta fotocamera e impostazioni. |
| `Haptics.swift`, `GlassStyle.swift` | Aptica e stile vetro. |

## Gesti
- Tap sul mirino: messa a fuoco; poi trascina in verticale per l'esposizione.
- Pizzico: zoom (1×–10×). Secondo tocco sull'otturatore durante il timer: annulla.

## Prima di pubblicare sull'App Store
- Le fotocamere usano nomi neutri (nessun marchio). Mantienili così.
- Aggiungi screenshot e una privacy policy: l'app usa fotocamera e libreria Foto (solo scrittura).
