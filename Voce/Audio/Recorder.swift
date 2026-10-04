import Accelerate
@preconcurrency import AVFoundation

/// Microfono → `[Float]` 16 kHz mono (§4.2). Il tap gira sul thread audio, lo stato condiviso è protetto da lock.
final class Recorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private static let prerollSamples = 4_800   // 300 ms

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var capturing = false
    private var levelPeak: Float = 0
    private var tapInstalled = false
    private var observer: NSObjectProtocol?

    /// Engine sempre attivo con pre-roll di 300 ms: da attivare se si perde la prima sillaba (indicatore arancione fisso).
    var warmMic = false {
        didSet {
            guard warmMic != oldValue else { return }
            if warmMic { try? startEngine() } else if !isCapturing { engine.stop(); engine.prepare() }
        }
    }

    var isCapturing: Bool { lock.withLock { capturing } }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.reconfigure() }
    }

    /// Da chiamare all'avvio: alloca le risorse così `start()` al keydown è il più rapido possibile.
    func prepare() {
        installTap()
        engine.prepare()
        if warmMic { try? startEngine() }
    }

    func start() throws {
        lock.withLock {
            samples = warmMic ? preroll : []
            samples.reserveCapacity(16_000 * 30)
            capturing = true
        }
        do { try startEngine() } catch {
            lock.withLock { capturing = false }
            throw error
        }
    }

    var sampleCount: Int { lock.withLock { samples.count } }

    /// RMS massimo dei buffer arrivati dall'ultima lettura (0…1): alimenta la waveform del HUD.
    func consumeLevel() -> Float {
        lock.withLock {
            defer { levelPeak = 0 }
            return levelPeak
        }
    }

    /// Copia dei campioni registrati finora da `index` in poi, senza fermare la registrazione.
    func peek(from index: Int) -> [Float] {
        lock.withLock { index < samples.count ? Array(samples[index...]) : [] }
    }

    func stop() -> [Float] {
        let out: [Float] = lock.withLock {
            capturing = false
            defer { samples = [] }
            return samples
        }
        if !warmMic {
            engine.stop()
            engine.prepare()
        }
        return out
    }

    func cancel() { _ = stop() }

    // MARK: - Engine

    private func startEngine() throws {
        if !tapInstalled { installTap() }
        guard tapInstalled else { throw RecorderError.noInput }
        if !engine.isRunning { try engine.start() }
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { tapInstalled = false; return }
        let conv = AVAudioConverter(from: format, to: target)
        conv?.downmix = true
        converter = conv
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
    }

    /// Cuffie Bluetooth, cambio del dispositivo di default ecc.: il formato d'ingresso cambia e l'engine si ferma.
    private func reconfigure() {
        let wasRunning = isCapturing || warmMic
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine.stop()
        installTap()
        engine.prepare()
        if wasRunning { try? startEngine() }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(out.frameLength))

        lock.withLock {
            if capturing {
                samples.append(contentsOf: chunk)
                levelPeak = max(levelPeak, rms)
            } else if warmMic {
                preroll.append(contentsOf: chunk)
                if preroll.count > Self.prerollSamples { preroll.removeFirst(preroll.count - Self.prerollSamples) }
            }
        }
    }

    // MARK: - Utilità

    /// C'è voce? RMS massimo su finestre di 30 ms sopra soglia (default ≈ −42 dBFS).
    static func hasVoice(_ s: [Float], threshold: Float) -> Bool {
        let frame = 480
        var i = 0
        while i + frame <= s.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += s[j] * s[j] }
            if (sum / Float(frame)).squareRoot() > threshold { return true }
            i += frame
        }
        return false
    }

    static func duration(_ s: [Float]) -> TimeInterval { Double(s.count) / sampleRate }

    /// WAV PCM 16 bit, 16 kHz mono (dataset personale, §10.1).
    static func writeWAV(_ s: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)) else { return }
        buf.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        try file.write(from: buf)
    }
}

enum RecorderError: LocalizedError {
    case noInput
    var errorDescription: String? { "Nessun microfono disponibile" }
}
