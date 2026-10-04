import Foundation

// MARK: - CLI (`Voce transcribe` è usata da tools/eval.py; `Voce meeting` prova l'elaborazione delle riunioni)

enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        var model = Transcriber.Model.ultra
        var boost = true
        var segmented = false
        var language = SpeechLanguage.auto
        var dictPath: String?
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model": i += 1; model = Transcriber.Model(rawValue: args[safe: i] ?? "") ?? .ultra
            case "--no-boost": boost = false
            case "--segmented": segmented = true
            case "--dict": i += 1; dictPath = args[safe: i]
            case "--lang": i += 1; language = SpeechLanguage(rawValue: args[safe: i] ?? "") ?? .auto
            default: files.append(args[i])
            }
            i += 1
        }
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("uso: Voce transcribe [--model ultra|v3] [--no-boost] [--segmented] [--lang auto|it|en] [--dict file.json] file.wav…\n".utf8))
            return 2
        }
        var dictionary = PersonalDictionary.load()
        if let dictPath, let data = FileManager.default.contents(atPath: dictPath),
           let custom = try? JSONDecoder().decode(PersonalDictionary.self, from: data) { dictionary = custom }

        do {
            try await Transcriber.shared.load(model)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for file in files {
                let samples = try Transcriber.loadAudio(file)
                let terms = boost ? Transcriber.vocabulary(for: dictionary) : []
                var tr: Transcription
                if segmented {
                    // Stessa logica dell'app: tagli nelle pause ogni volta che l'audio pendente supera la soglia.
                    var parts: [Transcription] = []
                    var rest = samples[...]
                    while Recorder.duration(Array(rest)) >= Segmenter.triggerSeconds {
                        let cut = Segmenter.cutPoint(Array(rest))
                        parts.append(try await Transcriber.shared.transcribe(Array(rest.prefix(cut)), terms: terms, language: language))
                        rest = rest.dropFirst(cut)
                    }
                    parts.append(try await Transcriber.shared.transcribe(Array(rest), terms: terms, language: language))
                    tr = Transcription.merge(parts)
                } else {
                    tr = try await Transcriber.shared.transcribe(samples, terms: terms, language: language)
                }
                let ruled = Rules.apply(tr.boosted, profile: .agentIDE, sendOnInvia: false, language: language)
                let final = boost ? Rules.tidy(dictionary.apply(ruled.text)) : ruled.text
                let row = ["file": file, "model": model.rawValue, "boost": boost ? "1" : "0",
                           "raw": tr.raw, "boosted": tr.boosted, "final": final, "asr_ms": String(tr.asrMs),
                           "boost_ms": String(tr.boostMs), "segments": String(tr.segments)]
                FileHandle.standardOutput.write(try enc.encode(row) + Data("\n".utf8))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("errore: \(error)\n".utf8))
            return 1
        }
    }
}

extension CLI {
    /// `Voce meeting [--lang auto|it|en] file.wav` → trascrizione con i parlanti in Markdown su stdout, tempi su stderr.
    static func meeting(_ args: [String]) async -> Int32 {
        var language = SpeechLanguage.auto
        var files: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--lang" { i += 1; language = SpeechLanguage(rawValue: args[safe: i] ?? "") ?? .auto } else { files.append(args[i]) }
            i += 1
        }
        guard let file = files.first.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else {
            FileHandle.standardError.write(Data("uso: Voce meeting [--lang auto|it|en] file.wav\n".utf8))
            return 2
        }
        do {
            try await Transcriber.shared.load(Prefs.model)
            let started = Date()
            let meeting = Meeting(id: "cli", title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent,
                                  createdAt: Date(), source: .imported, state: .processing, tracks: [.init(kind: .mixed, file: file)])
            let result = try await MeetingPipeline.run(meeting, language: language) { stage, done in
                FileHandle.standardError.write(Data("\r\(stage) \(Int(MeetingPipeline.fraction(stage, done) * 100))%   ".utf8))
            }
            FileHandle.standardError.write(Data("\n\(String(format: "%.1f", Date().timeIntervalSince(started))) s per \(Int(result.duration)) s di audio\n".utf8))
            print(result.markdown())
            return 0
        } catch {
            FileHandle.standardError.write(Data("errore: \(error)\n".utf8))
            return 1
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
