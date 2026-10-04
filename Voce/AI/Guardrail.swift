import Foundation

// MARK: - Livello 3: LLM (§6.3)

enum Guardrail {
    static let badPrefixes = ["ecco", "certo", "sure", "here is", "here's"]

    /// `nil` se l'output è accettabile, altrimenti il motivo dello scarto.
    static func violation(input: String, output: String) -> String? {
        let inLen = max(1, input.count)
        let ratio = Double(output.count) / Double(inLen)
        if output.isEmpty { return "vuoto" }
        if ratio > 1.6 { return "troppo lungo (\(String(format: "%.2f", ratio))×)" }
        if ratio < 0.4 { return "troppo corto (\(String(format: "%.2f", ratio))×)" }
        let lower = output.lowercased()
        if let p = badPrefixes.first(where: { lower.hasPrefix($0) && !input.lowercased().hasPrefix($0) }) {
            return "inizia con \"\(p)\""
        }
        // Una pulizia conserva quasi tutte le parole: se ne sopravvive meno della metà, il modello ha "risposto".
        let overlap = wordOverlap(input: input, output: output)
        if overlap < 0.5 { return "contenuto diverso (\(Int(overlap * 100))% parole conservate)" }
        return nil
    }

    /// Frazione delle parole dell'input (≥ 3 lettere) presenti nell'output.
    static func wordOverlap(input: String, output: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        }
        let inWords = words(input)
        guard !inWords.isEmpty else { return 1 }
        let outWords = Set(words(output))
        return Double(inWords.filter(outWords.contains).count) / Double(inWords.count)
    }

    /// Il testo da mostrare mentre la risposta arriva a pezzi: senza i blocchi <think>, anche quello ancora aperto.
    static func visible(_ partial: String) -> String {
        var s = partial.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        if let open = s.range(of: "<think>") { s = String(s[..<open.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ripulisce l'output grezzo del modello: blocchi <think>, virgolette o backtick che avvolgono tutto.
    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") && s.hasSuffix("```") && s.count > 6 {
            s = String(s.dropFirst(3).dropLast(3))
            if let nl = s.firstIndex(of: "\n"), !s[..<nl].contains(" ") { s = String(s[s.index(after: nl)...]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("«", "»")] where s.hasPrefix(open) && s.hasSuffix(close) && s.count > 1 {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
