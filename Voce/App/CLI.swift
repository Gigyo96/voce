import Foundation

// MARK: - CLI (usata da tools/eval.py)

enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        var model = Transcriber.Model.ultra
        var boost = true
        var segmented = false
        var dictPath: String?
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model": i += 1; model = Transcriber.Model(rawValue: args[safe: i] ?? "") ?? .ultra
            case "--no-boost": boost = false
            case "--segmented": segmented = true
            case "--dict": i += 1; dictPath = args[safe: i]
            default: files.append(args[i])
            }
            i += 1
        }
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("uso: Voce transcribe [--model ultra|v3] [--no-boost] [--segmented] [--dict file.json] file.wav…\n".utf8))
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
                        parts.append(try await Transcriber.shared.transcribe(Array(rest.prefix(cut)), terms: terms))
                        rest = rest.dropFirst(cut)
                    }
                    parts.append(try await Transcriber.shared.transcribe(Array(rest), terms: terms))
                    tr = Transcription.merge(parts)
                } else {
                    tr = try await Transcriber.shared.transcribe(samples, terms: terms)
                }
                let ruled = Rules.apply(tr.boosted, profile: .agentIDE, sendOnInvia: false)
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

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
