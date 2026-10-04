import FluidAudio
import Foundation

/// «Chi parla quando»: separazione dei parlanti con i modelli di FluidAudio (segmentazione pyannote + embedding WeSpeaker
/// + clustering VBx), tutto in locale. I modelli (qualche decina di MB) si scaricano la prima volta che serve.
actor Diarizer {
    static let shared = Diarizer()

    /// Il gestore di FluidAudio non è `Sendable`, ma qui lo usa una richiesta alla volta (l'actor le mette in coda).
    private final class Box: @unchecked Sendable {
        let manager = OfflineDiarizerManager()
        var ready = false
    }

    private let box = Box()

    /// Intervalli per parlante in secondi dall'inizio di `samples` (16 kHz mono), ordinati per inizio.
    func spans(_ samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [SpeakerSpan] {
        try await prepare()
        let result = try await box.manager.process(audio: samples) { done, total in
            if total > 0 { progress?(Double(done) / Double(total)) }
        }
        return result.segments
            .map { SpeakerSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }

    private func prepare() async throws {
        guard !box.ready else { return }
        try await box.manager.prepareModels()
        box.ready = true
    }
}
