import AVFoundation

/// Effetti sonori sintetizzati in codice (nessun file audio): click meccanico dell'otturatore,
/// tick del timer, "ding" di conferma della messa a fuoco e piccolo click degli interruttori (acceso: sale, spento: scende). L'utente può disattivarli (chiave "soundEnabled").
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    private enum Kind: CaseIterable { case shutter, tick, focus, toggleOn, toggleOff }

    private let sampleRate = 44_100.0
    private let engine = AVAudioEngine()
    private var nodes: [Kind: AVAudioPlayerNode] = [:]
    private var buffers: [Kind: AVAudioPCMBuffer] = [:]
    private var isPrepared = false

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
    }

    // MARK: API
    func shutter() { play(.shutter) }
    func timerTick() { play(.tick) }
    func focusBeep() { play(.focus) }
    /// Interruttore attivato (suono che sale) o disattivato (suono che scende).
    func toggle(_ on: Bool) { play(on ? .toggleOn : .toggleOff) }

    /// Chiamala all'avvio: costruisce i buffer e avvia il motore audio.
    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        // .ambient: non interrompe la musica dell'utente e rispetta il tasto silenzioso
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        for kind in Kind.allCases {
            guard let buffer = makeBuffer(for: kind, format: format) else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes[kind] = node
            buffers[kind] = buffer
        }
        // Attivazione asincrona: setActive(true) sul main thread può bloccare l'interfaccia (avviso di runtime di iOS)
        Task { @MainActor in
            await activateSession()
            startEngine()
        }
    }

    /// Attiva la sessione audio senza bloccare il main thread: API asincrona da iOS 27, su versioni precedenti una coda in background.
    private nonisolated func activateSession() async {
        if #available(iOS 27.0, *) {
            _ = try? await AVAudioSession.sharedInstance().activate()
        } else {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    done.resume()
                }
            }
        }
    }

    // MARK: Riproduzione
    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    private func play(_ kind: Kind) {
        guard isEnabled else { return }
        if !isPrepared { prepare() }
        startEngine()     // il motore si ferma dopo interruzioni o cambi di route
        guard engine.isRunning, let node = nodes[kind], let buffer = buffers[kind] else { return }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    // MARK: Sintesi
    private func makeBuffer(for kind: Kind, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration: Double
        switch kind {
        case .shutter: duration = 0.16
        case .tick:    duration = 0.06
        case .focus:   duration = 0.14
        case .toggleOn, .toggleOff: duration = 0.06
        }
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        var noise = NoiseSource()
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var s: Double
            switch kind {
            case .shutter:
                // Un solo "tic" breve e morbido, quasi impercettibile: attacco di 3 ms (niente scatto secco),
                // una nota alta che svanisce in fretta e un tocco di corpo grave sotto
                s = softTone(t, freq: 1250, attack: 0.003, decay: 0.014) * 0.24
                  + softTone(t, freq: 190, attack: 0.004, decay: 0.022) * 0.14
                  // Timbro metallico: parziali non armoniche (rapporti da lamella di metallo) che si spengono piano,
                  // come il tintinnio delle lamelle del diaframma dopo lo scatto
                  + softTone(t, freq: 2350, attack: 0.002, decay: 0.05) * 0.07
                  + softTone(t, freq: 3920, attack: 0.002, decay: 0.035) * 0.04
                  + softTone(t, freq: 6480, attack: 0.002, decay: 0.022) * 0.02
            case .tick:
                // Tocco sordo e breve, senza il sibilo acuto di prima
                s = softTone(t, freq: 700, attack: 0.004, decay: 0.014) * 0.32
            case .focus:
                // Un solo "ding" morbido (note basse), al posto del doppio bip acuto
                s = softTone(t, freq: 1046, attack: 0.008, decay: 0.045) * 0.3
                  + softTone(t, freq: 1568, attack: 0.008, decay: 0.03) * 0.08
            case .toggleOn:
                s = blip(t, from: 620, to: 880)
            case .toggleOff:
                s = blip(t, from: 760, to: 520)
            }
            data[i] = Float(max(-1, min(1, s)))
        }
        return buffer
    }

    /// Un singolo colpo meccanico che parte a `at` secondi.
    private func click(_ t: Double, at start: Double, decay: Double, tone: Double, thump: Double,
                       noise: inout NoiseSource) -> Double {
        let x = t - start
        guard x >= 0 else { return 0 }
        let env = exp(-x / decay)
        let hiss = noise.next() * env * 0.18          // meno fruscio: era la parte più "ruvida"
        let body = sin(2 * .pi * tone * x) * min(1, x / 0.002) * env * 0.35
        let low = sin(2 * .pi * thump * x) * exp(-x / (decay * 2.6)) * 0.7
        return hiss + body + low
    }

    /// Piccolo "pop" di 40 ms con la frequenza che scivola da `from` a `to`: morbido, non fastidioso.
    private func blip(_ t: Double, from f0: Double, to f1: Double) -> Double {
        let length = 0.055
        guard t < length else { return 0 }
        let phase = 2 * .pi * (f0 * t + (f1 - f0) * t * t / (2 * length))
        // Attacco di 8 ms (niente "click" iniziale) e chiusura dolce
        let env = min(1, t / 0.008) * exp(-t / 0.02) * min(1, (length - t) / 0.01)
        return sin(phase) * env * 0.22
    }

    /// Nota sinusoidale con attacco morbido e decadimento esponenziale.
    private func softTone(_ t: Double, freq: Double, attack: Double, decay: Double) -> Double {
        sin(2 * .pi * freq * t) * min(1, t / attack) * exp(-t / decay)
    }

    /// Bip sinusoidale di 45 ms con attacco e rilascio brevi (evita i "click" di inizio/fine).
    private func beep(_ t: Double, at start: Double, freq: Double) -> Double {
        let x = t - start, length = 0.045
        guard x >= 0, x < length else { return 0 }
        let env = min(1, x / 0.004) * min(1, (length - x) / 0.006)
        return sin(2 * .pi * freq * x) * env * 0.32
    }
}

/// Rumore bianco deterministico (LCG): lo stesso suono a ogni avvio.
private struct NoiseSource {
    private var state: UInt32 = 0x1234_5678
    mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state >> 8) / Double(1 << 23) - 1
    }
}
