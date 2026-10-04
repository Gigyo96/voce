import AVFoundation
import Foundation

/// Da una o più tracce audio alla riunione trascritta: parole con i tempi (Parakeet), parlanti (diarizzazione),
/// interventi attribuiti. Tutto in locale; l'AI di testo entra solo dopo, per riepilogo e domande.
enum MeetingPipeline {
    enum Stage: Sendable { case transcribing, separating, finishing }

    /// Quanto pesa ogni fase sulla barra di avanzamento.
    private static let weights: [Stage: (from: Double, to: Double)] = [
        .transcribing: (0, 0.6), .separating: (0.6, 0.95), .finishing: (0.95, 1),
    ]

    static func fraction(_ stage: Stage, _ done: Double) -> Double {
        let w = weights[stage] ?? (0, 1)
        return w.from + (w.to - w.from) * min(max(done, 0), 1)
    }

    /// Elabora `meeting` e ne restituisce la versione con trascrizione. Non scrive nulla sul disco tranne il mix da riascoltare.
    static func run(_ meeting: Meeting, language: SpeechLanguage, progress: @escaping @Sendable (Stage, Double) -> Void) async throws -> Meeting {
        var meeting = meeting
        let rate = Recorder.sampleRate

        // 1. Carica le tracce, allineate all'inizio della riunione.
        var tracks: [(info: Meeting.Track, samples: [Float])] = []
        for info in meeting.tracks {
            var samples = try await AudioFileLoader.samples(at: meeting.url(info.file))
            if info.offset > 0 { samples.insert(contentsOf: [Float](repeating: 0, count: Int(info.offset * rate)), at: 0) }
            tracks.append((info, samples))
        }
        guard !tracks.isEmpty else { throw MeetingError.noAudio }
        meeting.duration = Recorder.duration(tracks.map(\.samples).max { $0.count < $1.count } ?? [])

        // 2. Senza cuffie il microfono ripete l'audio del Mac: si toglie l'eco prima di trascrivere.
        let system = tracks.first { $0.info.kind == .system }?.samples
        let dictionary = PersonalDictionary.load()
        let total = Double(tracks.reduce(0) { $0 + $1.samples.count })
        var transcribed = 0.0
        // 3. Parole con i tempi, una traccia dopo l'altra.
        var transcripts: [(info: Meeting.Track, audio: [Float], words: [TimedWord])] = []
        for (info, samples) in tracks {
            let audio = info.kind == .mic && system != nil ? EchoGate.apply(mic: samples, system: system!) : samples
            let base = transcribed
            let words = try await Transcriber.shared.transcribeWords(audio, language: language) { done in
                progress(.transcribing, (base + done * Double(samples.count)) / max(total, 1))
            }
            transcribed += Double(samples.count)
            transcripts.append((info, audio, words))
        }
        let systemWords = transcripts.first { $0.info.kind == .system }?.words

        // 4. Chi parla: la traccia del microfono è solo «Io»; le altre si separano per voce.
        var lists: [[Meeting.Utterance]] = []
        for (info, audio, found) in transcripts {
            var words = found
            var spans: [SpeakerSpan] = []
            let fallback: String
            if info.kind == .mic {
                fallback = Meeting.meID
                if let systemWords { words = TranscriptBuilder.removeEcho(from: words, against: systemWords) }
            } else {
                fallback = "s1"
                if !words.isEmpty {
                    progress(.separating, 0)
                    spans = TranscriptBuilder.renumber(try await Diarizer.shared.spans(audio) { progress(.separating, $0) })
                }
            }
            lists.append(TranscriptBuilder.utterances(TranscriptBuilder.assign(words, to: spans, fallback: fallback)))
        }
        progress(.finishing, 0)

        // 5. Un'unica trascrizione, col dizionario personale applicato al testo.
        var utterances = TranscriptBuilder.merge(lists)
        for i in utterances.indices { utterances[i].text = Rules.tidy(dictionary.apply(utterances[i].text)) }
        utterances.removeAll { $0.text.isEmpty }
        meeting.utterances = utterances
        // Se i partecipanti erano già stati nominati (nuova elaborazione), i nomi restano.
        let known = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0.name) })
        meeting.speakers = Array(Set(utterances.map(\.speaker)))
            .sorted { a, b in a == Meeting.meID || (b != Meeting.meID && a < b) }
            .map { Meeting.Speaker(id: $0, name: known[$0] ?? nil) }

        // 6. Per riascoltare: mix compresso delle tracce (le registrazioni; un file importato resta com'è).
        if meeting.source == .recorded {
            meeting.audio = try writeMix(tracks.map(\.samples), to: meeting.url("audio.m4a")) ? "audio.m4a" : nil
        } else {
            meeting.audio = meeting.tracks.first?.file
        }
        return meeting
    }

    /// Somma le tracce (tutte a 16 kHz mono) e le comprime in AAC: ~15 MB all'ora.
    static func writeMix(_ tracks: [[Float]], to url: URL) throws -> Bool {
        let count = tracks.map(\.count).max() ?? 0
        guard count > 0 else { return false }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Recorder.sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_000 * 30
        var start = 0
        while start < count {
            let end = min(count, start + chunk)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: PCMConverter.target, frameCapacity: AVAudioFrameCount(end - start)) else { return false }
            buffer.frameLength = AVAudioFrameCount(end - start)
            let out = buffer.floatChannelData![0]
            for i in start..<end {
                var sum: Float = 0
                for t in tracks where i < t.count { sum += t[i] }
                out[i - start] = max(-1, min(1, sum))
            }
            try file.write(from: buffer)
            start = end
        }
        return true
    }
}

enum MeetingError: LocalizedError {
    case noAudio, noSpeech
    var errorDescription: String? {
        switch self {
        case .noAudio: return L("Nessun audio da elaborare.")
        case .noSpeech: return L("Nell'audio non c'è parlato.")
        }
    }
}
