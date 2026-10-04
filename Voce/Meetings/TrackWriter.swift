@preconcurrency import AVFoundation

/// Scrive una traccia a 16 kHz mono su disco mentre arriva, senza tenerla in memoria. Formato CAF: se l'app si chiude di
/// colpo il file resta leggibile fino all'ultimo campione (un WAV senza intestazione finale no).
final class TrackWriter: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private let io = DispatchQueue(label: "it.dimarcantonio.voce.track-writer", qos: .utility)
    private let lock = NSLock()
    private var first: UInt64?
    private var level: Float = 0
    private var peak: Float = 0
    private var frames = 0
    private var muted = false

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Recorder.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Tempo (host time) del primo campione: serve ad allineare tracce che partono con qualche millisecondo di scarto.
    var firstHostTime: UInt64? { lock.withLock { first } }
    /// Durata scritta, in secondi.
    var seconds: Double { lock.withLock { Double(frames) / Recorder.sampleRate } }
    /// Il livello massimo mai arrivato: zero esatto dopo molti secondi vuol dire che il permesso manca.
    var hasSignal: Bool { lock.withLock { peak > 0 } }

    /// Muto = si continua a scrivere, ma silenzio: la traccia resta allineata al resto.
    func setMuted(_ on: Bool) { lock.withLock { muted = on } }

    func append(_ samples: [Float], hostTime: UInt64) {
        let (data, silent): ([Float], Bool) = lock.withLock {
            if first == nil { first = hostTime }
            frames += samples.count
            let loud = samples.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
            peak = max(peak, loud)
            level = max(level, muted ? 0 : loud)
            return (samples, muted)
        }
        let out = silent ? [Float](repeating: 0, count: data.count) : data
        io.async { [self] in
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: PCMConverter.target, frameCapacity: AVAudioFrameCount(out.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(out.count)
            out.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
            try? file.write(from: buffer)
        }
    }

    /// Picco dall'ultima lettura (0…1) per il misuratore.
    func consumeLevel() -> Float {
        lock.withLock {
            defer { level = 0 }
            return level
        }
    }

    /// Chiude il file dopo le scritture in coda.
    func close() {
        io.sync { file = nil }
    }
}
