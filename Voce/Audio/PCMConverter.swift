@preconcurrency import AVFoundation

/// Qualsiasi buffer audio (microfono, tap di sistema…) → `[Float]` a 16 kHz mono, il formato che serve a Parakeet.
/// Un'istanza per sorgente, usata da un solo thread alla volta (il callback audio): il convertitore tiene lo stato.
final class PCMConverter: @unchecked Sendable {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: Self.target) else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
