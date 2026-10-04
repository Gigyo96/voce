import Foundation

// MARK: - Testo in tempo reale mentre si parla

/// Mostra nel HUD quello che stai dicendo, mentre lo dici (Generale › Mostra il testo mentre parli).
///
/// Niente secondo modello di streaming: ogni mezzo secondo lo stesso Parakeet già caricato ritrascrive l'audio non
/// ancora coperto dai segmenti finiti (~70 ms per 5 s sull'ANE, senza boosting). Così l'anteprima converge al testo
/// che verrà incollato e non serve altra memoria. Le trascrizioni restano una alla volta, mai accodate.
@MainActor final class LivePreview {
    static let interval: Duration = .milliseconds(500)

    private var loop: Task<Void, Never>?
    private(set) var session = 0      // cambia a ogni dettatura: i risultati di quelle vecchie si scartano
    private var finished: [String] = []   // testo dei segmenti già trascritti, in ordine
    private var finishedSamples = 0       // campioni coperti da `finished`

    func start(recorder: Recorder, language: SpeechLanguage, dictionary: PersonalDictionary,
               update: @escaping (String) -> Void) {
        stop()
        session += 1
        let session = self.session
        loop = Task { [weak self] in
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled, session == self.session else { return }
                let start = self.finishedSamples
                let pending = recorder.peek(from: start)
                // Niente da aggiornare: troppo poco audio, oppure nessun campione nuovo dall'ultima volta.
                guard Recorder.duration(pending) >= 0.5, start + pending.count != lastCount else { continue }
                lastCount = start + pending.count
                guard let tail = try? await Transcriber.shared.transcribe(pending, terms: [], language: language),
                      !Task.isCancelled, session == self.session, start == self.finishedSamples else { continue }
                update(Self.format(self.finished + [tail.raw], dictionary: dictionary, language: language))
            }
        }
    }

    /// Un segmento della dettatura lunga è stato trascritto: da qui in poi l'anteprima riparte dopo di lui.
    func segmentFinished(_ text: String, upTo samples: Int, session: Int) {
        guard session == self.session else { return }
        finished.append(text)
        finishedSamples = samples
    }

    func stop() {
        loop?.cancel()
        loop = nil
        session += 1
        finished = []
        finishedSamples = 0
    }

    /// Le stesse pulizie del testo finale (esitazioni, comandi vocali, dizionario), senza LLM.
    nonisolated static func format(_ parts: [String], dictionary: PersonalDictionary, language: SpeechLanguage) -> String {
        let ruled = Rules.apply(Segmenter.join(parts), profile: .plain, sendOnInvia: false, language: language)
        return Rules.tidy(dictionary.apply(ruled.text))
    }

    /// Le ultime ~`limit` lettere, tagliate a inizio parola: nel HUD si legge sempre la fine di ciò che hai detto.
    nonisolated static func tail(_ text: String, limit: Int = 165) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        guard flat.count > limit else { return flat }
        let cut = flat.suffix(limit)
        let word = cut.firstIndex(of: " ").map { cut[cut.index(after: $0)...] } ?? cut
        return "…" + word
    }
}
