import AVFoundation

/// Effetti sonori sintetizzati in codice (nessun file audio): click meccanico dell'otturatore,
/// tick del timer e bip di conferma della messa a fuoco. L'utente può disattivarli (chiave "soundEnabled").
@MainActor
final class SoundFX {
    static let shared = SoundFX()

    private enum Kind: CaseIterable { case shutter, tick, focus }

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

    /// Chiamala all'avvio: costruisce i buffer e avvia il motore audio.
    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        // .ambient: non interrompe la musica dell'utente e rispetta il tasto silenzioso
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        for kind in Kind.allCases {
            guard let buffer = makeBuffer(for: kind, format: format) else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes[kind] = node
            buffers[kind] = buffer
        }
        startEngine()
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
        case .tick:    duration = 0.05
        case .focus:   duration = 0.17
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
                // Specchio + tendina: due colpi secchi (rumore filtrato + tonfo grave)
                s = click(t, at: 0.000, decay: 0.010, tone: 1900, thump: 150, noise: &noise) * 0.9
                  + click(t, at: 0.055, decay: 0.016, tone: 1150, thump: 95, noise: &noise) * 0.75
            case .tick:
                s = sin(2 * .pi * 1400 * t) * exp(-t / 0.011) * 0.5
            case .focus:
                // Doppio bip di conferma, come le compatte
                s = beep(t, at: 0.000, freq: 2600) + beep(t, at: 0.085, freq: 2600)
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
        let hiss = noise.next() * env * 0.55
        let body = sin(2 * .pi * tone * x) * env * 0.35
        let low = sin(2 * .pi * thump * x) * exp(-x / (decay * 2.6)) * 0.7
        return hiss + body + low
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
