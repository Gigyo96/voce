import Foundation

/// Cosa far leggere al modello di una riunione. Una riunione di un'ora sono ~15 000 token: se non stanno nel contesto
/// del modello (impostabile in Funzioni AI) si dà un riassunto per blocchi di tutta la riunione più i passaggi della
/// trascrizione che parlano della domanda, scelti per parole in comune.
enum MeetingContext {
    struct Chunk: Equatable {
        var start: Double
        var text: String
    }

    /// Caratteri di trascrizione che stanno nel contesto: il 60% dei token (circa 3,5 caratteri l'uno); il resto è
    /// per le istruzioni, la cronologia della chat e la risposta.
    static func budget(tokens: Int) -> Int { Int(Double(tokens) * 3.5 * 0.6) }

    /// Gli interventi raggruppati in blocchi di al massimo `maxChars` caratteri (un intervento non si spezza).
    static func chunks(of meeting: Meeting, maxChars: Int) -> [Chunk] {
        var out: [Chunk] = []
        var text = "", start = 0.0
        for u in meeting.utterances {
            let line = meeting.line(u)
            if !text.isEmpty, text.count + line.count + 1 > maxChars {
                out.append(Chunk(start: start, text: text))
                text = ""
            }
            if text.isEmpty { start = u.start }
            text += (text.isEmpty ? "" : "\n") + line
        }
        if !text.isEmpty { out.append(Chunk(start: start, text: text)) }
        return out
    }

    static func fits(_ meeting: Meeting, budget: Int) -> Bool {
        meeting.utterances.reduce(0) { $0 + $1.text.count + 24 } <= budget
    }

    // MARK: Ricerca per parole in comune

    private static let stopwords: Set<String> = [
        "che", "chi", "cosa", "come", "quando", "dove", "perché", "quale", "quali", "quanto", "della", "delle", "dello",
        "degli", "dei", "del", "nel", "nella", "nelle", "sul", "sulla", "per", "con", "una", "uno", "gli", "alla", "alle",
        "sono", "stato", "stata", "hanno", "detto", "parlato", "riunione", "meeting",
        "the", "what", "when", "where", "who", "how", "why", "which", "was", "were", "did", "does", "about", "with",
        "for", "and", "that", "this", "from", "said", "talked", "meeting",
    ]

    /// Radici delle parole della domanda (prime 5 lettere: «decisione», «decisioni», «deciso» si incontrano).
    static func stems(_ text: String) -> [String] {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Array(Set(words.filter { $0.count >= 3 && !stopwords.contains($0) }.map { String($0.prefix(5)) }))
    }

    /// I blocchi che parlano della domanda, in ordine di tempo, fino a `maxChars` caratteri. Punteggio: per ogni radice
    /// della domanda, quante volte compare nel blocco, pesata per quanto è rara nel resto della riunione (tf-idf).
    static func relevant(to question: String, in chunks: [Chunk], maxChars: Int) -> [Chunk] {
        let terms = stems(question)
        guard !terms.isEmpty, !chunks.isEmpty else { return [] }
        let tokenized = chunks.map { chunk in
            chunk.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        var score = [Double](repeating: 0, count: chunks.count)
        for term in terms {
            let counts = tokenized.map { $0.filter { $0.hasPrefix(term) }.count }
            let df = Double(counts.filter { $0 > 0 }.count)
            let idf = Foundation.log(1 + Double(chunks.count) / (1 + df))
            for (i, c) in counts.enumerated() where c > 0 { score[i] += idf * (1 + Foundation.log(Double(c))) }
        }
        var picked: [Int] = [], used = 0
        for i in chunks.indices.sorted(by: { score[$0] > score[$1] }) where score[i] > 0 {
            guard used + chunks[i].text.count <= maxChars else { continue }
            picked.append(i)
            used += chunks[i].text.count
        }
        return picked.sorted().map { chunks[$0] }
    }

    // MARK: Materiale per il modello

    /// La parte «dati» del messaggio: trascrizione completa se sta nel contesto, altrimenti appunti + passaggi rilevanti.
    static func material(for meeting: Meeting, question: String, budget: Int) -> String {
        if fits(meeting, budget: budget) { return "TRASCRIZIONE:\n" + meeting.transcriptText() }
        var notes = (meeting.digest ?? []).joined(separator: "\n\n")
        if notes.count > budget / 2 { notes = String(notes.prefix(budget / 2)) }
        // Blocchi piccoli rispetto al budget: devono starcene più d'uno, e più sono corti più il passaggio è mirato.
        let excerpts = relevant(to: question, in: chunks(of: meeting, maxChars: max(500, min(3_000, budget / 4))), maxChars: budget - notes.count)
        var out = ""
        if !notes.isEmpty { out += "APPUNTI DELL'INTERA RIUNIONE (riassunti per blocchi, in ordine di tempo):\n\(notes)\n\n" }
        if !excerpts.isEmpty { out += "PASSAGGI DELLA TRASCRIZIONE PIÙ ATTINENTI ALLA DOMANDA:\n" + excerpts.map(\.text).joined(separator: "\n[…]\n") }
        return out.isEmpty ? "TRASCRIZIONE (parziale):\n" + String(meeting.transcriptText().prefix(budget)) : out
    }

    /// Intestazione con i dati della riunione.
    static func header(_ meeting: Meeting) -> String {
        let names = meeting.speakers.sorted { meeting.talkTime(of: $0.id) > meeting.talkTime(of: $1.id) }
            .map { meeting.name(of: $0.id) }.joined(separator: ", ")
        var out = "RIUNIONE: \(meeting.title)\nDATA: \(meeting.createdAt.formatted(date: .long, time: .shortened))\n"
            + "DURATA: \(Meeting.clock(meeting.duration))\nPARTECIPANTI: \(names)"
        if let notes = meeting.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out += "\nAPPUNTI DELL'UTENTE (contesto da tenere presente, non sono detti in riunione):\n\(notes)"
        }
        return out
    }
}

/// Istruzioni per il modello, dalla `PromptLibrary` (personalizzabili nella pagina Prompt). Il modello risponde nella
/// lingua dell'utente: la riunione può essere in una lingua e la domanda in un'altra.
enum MeetingPrompts {
    static var summary: String { PromptStore.shared.text(.meetingSummary) }
    static var notes: String { PromptStore.shared.text(.meetingNotes) }
    static var names: String { PromptStore.shared.text(.meetingNames) }
    static func chat(_ meeting: Meeting) -> String { PromptStore.shared.render(.meetingChat, ["riunione": MeetingContext.header(meeting)]) }
}
