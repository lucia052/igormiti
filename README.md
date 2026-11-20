# RetroCam (Lumora)

App iPhone (SwiftUI, iOS 17+, Liquid Glass su iOS 26+) con quattro fotocamere retrò in tempo reale: mirino filtrato, flash simulato con maschera persona, ghiera di messa a fuoco manuale, Live Photo, aptica.

## Come aprirla
1. Apri `RetroCam.xcodeproj` con Xcode 26 o successivo.
2. In *Signing & Capabilities* scegli il tuo Team.
3. Collega un iPhone vero e premi Run. Nel simulatore la fotocamera non esiste: vedrai solo il gradiente di riserva.

## Impostazioni di build importanti
- `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` e `SWIFT_VERSION = 5.0`: già impostati. Servono perché `CameraManager` lavora su code AVFoundation, non sul main actor.
- Il gruppo `RetroCam/` è sincronizzato: i file nuovi vengono inclusi da soli.

## Struttura
| Cartella | File | Ruolo |
|---|---|---|
| `App/` | `RetroCamApp`, `OpenCameraIntent` | Avvio, rotazione, comando per il tasto azione e Siri. |
| `Camera/` | `CameraManager` | Sessione AVFoundation, front/back, zoom, esposizione, fuoco, salvataggio, Live Photo. |
| | `CameraRecipe` | Dati delle quattro fotocamere (Ambra, Cristallo, Istante, Nastro). Aggiungerne una = aggiungere una ricetta a `all`. |
| | `DeviceProfile` | Adatta qualità del mirino e scatti in coda alla potenza del telefono, alla temperatura e al risparmio energetico. |
| `Filters/` | `FilterEngine` | Pipeline Core Image: ottica, flash, LUT 3D, bloom, nastro, leak, grana, polvere, overlay, cornice. |
| `UI/` | `ContentView` | Schermata unica: mirino, gesti, comandi, tendine, timer. |
| | `ViewfinderComponents` | Mirino (disegnato in un layer, fuori da SwiftUI), riquadro di fuoco, griglia, schermata permessi. |
| | `FocusRingView`, `DialKit` | Ghiera di messa a fuoco e dinamica condivisa con la ghiera dello zoom. |
| | `CameraPickerSheet`, `LevelIndicator` | Impostazioni e livella. |
| `Design/` | `Brand` | Identità visiva dal logo: palette champagne/bronzo/nero caldo, diaframma, font monospaziato. |
| | `BrandMenu`, `GlassStyle` | Tendine nello stile del logo e vetro di sistema. |
| `Feedback/` | `Haptics`, `SoundFX` | Aptica e suoni sintetizzati in codice. |

## Gesti
- Tap sul mirino: messa a fuoco; poi trascina in verticale per l'esposizione.
- Pizzico: zoom (fino a 25×, secondo il modello). Secondo tocco sull'otturatore durante il timer: annulla.

## Prima di pubblicare sull'App Store
- Le fotocamere usano nomi neutri (nessun marchio). Mantienili così.
- Il target `RetroCamCapture` non ha sorgenti né `Info.plist` e il suo bundle ID è un segnaposto: va completato o rimosso.
- Aggiungi screenshot e una privacy policy: l'app usa fotocamera e libreria Foto (solo scrittura).
