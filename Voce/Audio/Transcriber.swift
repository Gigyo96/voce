import FluidAudio
import Foundation

/// Risultato di una trascrizione: testo grezzo, testo dopo il boosting del dizionario e tempi.
struct Transcription: Sendable {
    var raw: String        // uscita TDT di Parakeet
    var boosted: String    // dopo il rescoring CTC con il dizionario
    var asrMs: Int         // TDT
    var boostMs: Int = 0   // encoder CTC + rescoring
    var segments = 1

    /// Unisce i segmenti di una dettatura lunga; i tempi sono quelli dell'ultimo (l'unico atteso dopo il rilascio).
    static func merge(_ parts: [Transcription]) -> Transcription {
        guard let last = parts.last else { return Transcription(raw: "", boosted: "", asrMs: 0) }
        return Transcription(raw: Segmenter.join(parts.map(\.raw)), boosted: Segmenter.join(parts.map(\.boosted)),
                             asrMs: last.asrMs, boostMs: last.boostMs, segments: parts.count)
    }
}

/// Parakeet (v3 o Ultra, stessa API) via FluidAudio sull'ANE, trascrizione batch + boosting CTC (§2.2).
actor Transcriber {
    static let shared = Transcriber()

    /// "ultra" è il post-training di v3 di FluidAudio: stessa architettura e velocità, WER più basso su tutte
    /// le lingue FLEURS (italiano incluso). "v3" resta disponibile per il confronto con `eval.py`.
    enum Model: String, CaseIterable, Sendable {
        case ultra, v3
        var version: AsrModelVersion { self == .ultra ? .ultra : .v3 }
    }

    private var asr: AsrManager?
    private var loadedModel: Model?
    private var ctcModels: CtcModels?

    func load(_ model: Model, terms: [(term: String, aliases: [String])] = [], progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if loadedModel == model, asr != nil { return }
        let version = model.version
        let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { p in
            progress?(p.fractionCompleted * 0.85)
        })
        let manager = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize))
        try await manager.loadModels(models)
        asr = manager
        loadedModel = model
        progress?(0.9)

        // Encoder CTC 110M per il keyword spotting (~100 MB). Se manca, si trascrive senza boosting.
        do { ctcModels = try await CtcModels.downloadAndLoad() } catch { NSLog("Voce: CTC non disponibile: \(error)") }
        progress?(0.97)

        // Warm-up: la prima inferenza compila i grafi ANE (TDT e CTC) e costruisce il vocabolario del boosting;
        // meglio pagarla all'avvio che alla prima dettatura.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000), terms: terms)
        progress?(1)
    }

    /// Dopo qualche secondo di inattività l'ANE scende di frequenza e la prima inferenza costa il doppio.
    /// Chiamato alla pressione del tasto: mentre l'utente parla, un passaggio su 1 s di silenzio rimette
    /// in temperatura TDT e CTC, così al rilascio la trascrizione vera trova tutto caldo.
    func prewarm(terms: [(term: String, aliases: [String])]) async {
        guard asr != nil else { return }
        let t0 = Date()
        _ = try? await transcribe([Float](repeating: 0, count: 16_000), terms: terms)
        lastPrewarmMs = Int(Date().timeIntervalSince(t0) * 1000)
    }

    private(set) var lastPrewarmMs = 0

    /// Termini + alias per il rescorer: le forme parlate generate e le chiavi di `replace` che puntano al termine.
    static func vocabulary(for dictionary: PersonalDictionary) -> [(term: String, aliases: [String])] {
        dictionary.terms.map { term in
            var aliases = PersonalDictionary.spokenForms(of: term).filter { $0 != term }
            aliases += dictionary.replace.filter { $0.value == term }.map(\.key)
            return (term, aliases)
        }
    }

    func transcribe(_ samples: [Float], terms: [(term: String, aliases: [String])]) async throws -> Transcription {
        guard let asr else { throw ASRError.notInitialized }
        let start = Date()

        // Coda di silenzio: aiuta il decoder TDT a emettere l'ultima parola e rispetta la durata minima.
        let audio = samples + [Float](repeating: 0, count: max(4_000, 16_000 - samples.count))

        // L'encoder CTC del boosting non dipende dall'uscita TDT: gira in parallelo.
        let booster = terms.isEmpty ? nil : try? await booster(for: terms)
        async let spot: CtcKeywordSpotter.SpotKeywordsResult? = {
            guard let booster else { return nil }
            return try? await booster.spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: booster.vocabulary)
        }()

        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audio, decoderState: &state, language: .italian)
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrMs = Int(Date().timeIntervalSince(start) * 1000)
        var boosted = raw

        if let booster, let spot = await spot, !spot.logProbs.isEmpty, let timings = result.tokenTimings, !timings.isEmpty {
            let out = booster.rescorer.ctcTokenRescore(
                transcript: raw, tokenTimings: timings, logProbs: spot.logProbs, frameDuration: spot.frameDuration,
                cbw: booster.cbw, marginSeconds: 0.5, minSimilarity: Float(Self.minSimilarity))
            if out.wasModified {
                let pairs = out.replacements.compactMap { r in
                    r.shouldReplace ? r.replacementWord.map { (original: r.originalWord, term: $0) } : nil
                }
                boosted = Self.applyReplacements(pairs, to: raw, vocabulary: terms)
            }
        }
        return Transcription(raw: raw, boosted: boosted, asrMs: asrMs,
                             boostMs: Int(Date().timeIntervalSince(start) * 1000) - asrMs)
    }

    // MARK: - Arbitrato delle sostituzioni

    /// Il rescorer ricostruisce il testo dai timing (perde la punteggiatura) e, con un encoder CTC inglese
    /// sul parlato italiano, propone anche sostituzioni deboli. Qui si riapplicano sul testo grezzo solo
    /// quelle con alta similarità ortografica, senza inglobare articoli e preposizioni ai bordi.
    static let minSimilarity = 0.7
    private static let functionWords: Set<String> = [
        "a", "e", "o", "il", "lo", "la", "i", "gli", "le", "l", "un", "uno", "una", "di", "da", "in", "con", "su",
        "per", "tra", "fra", "che", "del", "della", "al", "alla", "nel", "nella", "the", "and", "of", "to", "an",
    ]

    static func applyReplacements(_ pairs: [(original: String, term: String)], to raw: String,
                                  vocabulary: [(term: String, aliases: [String])]) -> String {
        var text = raw
        for (original, term) in pairs {
            let termForms = ([term] + (vocabulary.first { $0.term == term }?.aliases ?? [])).map(normalize)
            let termWords = Set(termForms.flatMap { $0.split(separator: " ").map(String.init) })
            var words = original.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            while let w = words.first, functionWords.contains(w.lowercased()), !termWords.contains(w.lowercased()) { words.removeFirst() }
            while let w = words.last, functionWords.contains(w.lowercased()), !termWords.contains(w.lowercased()) { words.removeLast() }
            guard !words.isEmpty else { continue }
            let spoken = normalize(words.joined(separator: " "))
            let best = termForms.map { similarity(spoken.replacingOccurrences(of: " ", with: ""), $0.replacingOccurrences(of: " ", with: "")) }.max() ?? 0
            guard best >= minSimilarity else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"[\s\p{P}]+"#) + #"(?![\p{L}\p{N}])"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range, in: text) else { continue }
            text.replaceSubrange(r, with: term)
        }
        return text
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 1 − distanza di Levenshtein normalizzata.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(a.isEmpty ? b.count : prev[b.count]) / Double(max(a.count, b.count))
    }

    /// Qualsiasi file audio → 16 kHz mono Float32 (conversione di FluidAudio, niente parsing manuale dei WAV).
    static func loadAudio(_ path: String) throws -> [Float] {
        try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    }

    private struct Booster: Sendable {
        let key: [String]
        let vocabulary: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
        let cbw: Float
    }

    private var booster: Booster?

    /// Spotter + rescorer per il vocabolario corrente; ricostruiti solo quando il dizionario cambia.
    private func booster(for terms: [(term: String, aliases: [String])]) async throws -> Booster? {
        guard let ctcModels else { return nil }
        let key = terms.map { ([$0.term] + $0.aliases).joined(separator: "\u{1}") }
        if let booster, booster.key == key { return booster }

        let dir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        let tokenizer = try await CtcTokenizer.load(from: dir)
        let vocabulary = CustomVocabularyContext(terms: terms.compactMap { t in
            let ids = tokenizer.encode(t.term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: t.term, aliases: t.aliases.isEmpty ? nil : t.aliases, ctcTokenIds: ids)
        }, minSimilarity: Float(Self.minSimilarity))
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        // Niente "spotter rescue": con l'encoder CTC inglese sul parlato italiano produce falsi positivi
        // a similarità bassissima ("M, aggiungi uno" → "Claude Code").
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocabulary,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false), ctcModelDirectory: dir)
        let cbw = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count).cbw
        booster = Booster(key: key, vocabulary: vocabulary, spotter: spotter, rescorer: rescorer, cbw: cbw)
        return booster
    }
}
