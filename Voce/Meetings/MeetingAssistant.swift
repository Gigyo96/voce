import Foundation

/// L'AI di testo applicata a una riunione: riepilogo, chat con la trascrizione, nomi dei parlanti. Usa lo stesso servizio
/// dei comandi sul testo (Funzioni AI), con un'attesa più lunga. Alla trascrizione si arriva senza AI; qui serve.
@MainActor final class MeetingAssistant: ObservableObject {
    static let shared = MeetingAssistant()

    enum Job: Equatable { case summary, notes(done: Int, of: Int), answer, names }

    /// Cosa sta facendo l'assistente per ogni riunione.
    @Published private(set) var jobs: [String: Job] = [:]
    /// Il testo di riepilogo o risposta mentre arriva.
    @Published private(set) var partial: [String: String] = [:]
    @Published private(set) var failures: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private let store = MeetingStore.shared

    private var config: LLMConfig {
        var cfg = Prefs.llm(command: true)
        cfg.timeout = Double(Prefs.meetingTimeoutMs.value) / 1000
        return cfg
    }
    private var budget: Int { MeetingContext.budget(tokens: Prefs.meetingContextTokens.value) }

    func isBusy(_ id: String) -> Bool { jobs[id] != nil }

    func stop(_ id: String) { tasks[id]?.cancel() }

    // MARK: Riepilogo

    /// Genera riepilogo e titolo. Se `automatic`, un errore (servizio non configurato) non viene mostrato.
    func summarize(_ id: String, automatic: Bool = false) {
        guard !isBusy(id), let meeting = store.meeting(id), meeting.state == .ready else { return }
        begin(id, .summary) { [self] in
            let material = try await summaryMaterial(for: id)
            let messages = [LLMClient.Message(role: "system", content: MeetingPrompts.summary),
                            LLMClient.Message(role: "user", content: MeetingContext.header(meeting) + "\n\n" + material)]
            let text = try await collect(id, LLMClient.stream(messages, config: config, maxTokens: 2_048, temperature: 0.2))
            let (title, body) = Self.splitTitle(text)
            store.update(id) {
                $0.summary = body
                if let title, !$0.titleEdited { $0.title = title }
            }
        } onFailure: { [self] error in
            if !automatic { failures[id] = LLMClient.friendly(error) }
        }
    }

    /// Un riepilogo non parte dal «# Titolo»: lo separa dal resto.
    nonisolated static func splitTitle(_ text: String) -> (title: String?, body: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].hasPrefix("# ") else { return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let title = String(lines[first].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        lines.removeSubrange(...first)
        return (title.isEmpty ? nil : title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func summaryMaterial(for id: String) async throws -> String {
        guard let meeting = store.meeting(id) else { return "" }
        if MeetingContext.fits(meeting, budget: budget) { return "TRASCRIZIONE:\n" + meeting.transcriptText() }
        return "APPUNTI (riassunti per blocchi, in ordine di tempo):\n" + (try await digest(for: id)).joined(separator: "\n\n")
    }

    /// Riassunto per blocchi di tutta la riunione (passo «map»): si fa una volta e si conserva con la riunione.
    private func digest(for id: String) async throws -> [String] {
        if let existing = store.meeting(id)?.digest, !existing.isEmpty { return existing }
        guard let meeting = store.meeting(id) else { return [] }
        let chunks = MeetingContext.chunks(of: meeting, maxChars: min(budget, 12_000))
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            jobs[id] = .notes(done: i, of: chunks.count)
            notes.append(try await LLMClient.complete(system: MeetingPrompts.notes, user: chunk.text, config: config, maxTokens: 700))
        }
        store.update(id) { $0.digest = notes }
        return notes
    }

    // MARK: Chat

    func ask(_ id: String, _ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy(id), store.meeting(id) != nil else { return }
        store.update(id) { $0.chat.append(.init(role: .user, text: question)) }
        begin(id, .answer) { [self] in
            if let meeting = store.meeting(id), !MeetingContext.fits(meeting, budget: budget) { _ = try await digest(for: id) }
            jobs[id] = .answer
            guard let meeting = store.meeting(id) else { return }
            let system = MeetingPrompts.chat(meeting) + "\n\n" + MeetingContext.material(for: meeting, question: question, budget: budget)
            // Cronologia: gli ultimi scambi, ognuno con un tetto, perché il contesto resti alla trascrizione.
            let history = meeting.chat.suffix(12).map { LLMClient.Message(role: $0.role.rawValue, content: String($0.text.prefix(4_000))) }
            let text = try await collect(id, LLMClient.stream([.init(role: "system", content: system)] + history, config: config))
            store.update(id) { $0.chat.append(.init(role: .assistant, text: text)) }
        } onFailure: { [self] error in
            // Interrotta dall'utente o caduta a metà: quello che è arrivato si tiene.
            if let text = partial[id], !text.isEmpty { store.update(id) { $0.chat.append(.init(role: .assistant, text: text)) } }
            if !Task.isCancelled { failures[id] = LLMClient.friendly(error) }
        }
    }

    /// Dopo un errore: ripete l'ultima domanda senza duplicarla nella conversazione.
    func retry(_ id: String) {
        guard !isBusy(id), let last = store.meeting(id)?.chat.last, last.role == .user else { return }
        store.update(id) { _ = $0.chat.popLast() }
        ask(id, last.text)
    }

    func clearChat(_ id: String) {
        failures[id] = nil
        store.update(id) { $0.chat = [] }
    }

    // MARK: Nomi

    /// Chiede al modello i nomi detti in riunione («Grazie, Marco») e li applica ai parlanti senza nome.
    func suggestNames(_ id: String) {
        guard !isBusy(id), let meeting = store.meeting(id) else { return }
        begin(id, .names) { [self] in
            let transcript = meeting.utterances.map { meeting.line($0, speaker: { $0 }) }.joined(separator: "\n")
            let reply = try await LLMClient.complete(system: MeetingPrompts.names, user: String(transcript.prefix(budget)),
                                                    config: config, maxTokens: 300)
            let found = Self.parseNames(reply)
            guard !found.isEmpty else { failures[id] = L("Nella riunione nessuno dice il proprio nome."); return }
            store.update(id) { m in
                for i in m.speakers.indices where (m.speakers[i].name ?? "").isEmpty {
                    if let name = found[m.speakers[i].id] { m.speakers[i].name = name }
                }
                m.digest = nil
            }
        } onFailure: { [self] error in
            failures[id] = LLMClient.friendly(error)
        }
    }

    /// `{"s1": "Marco", "s2": null}` → `["s1": "Marco"]`; tollera testo attorno al JSON.
    nonisolated static func parseNames(_ reply: String) -> [String: String] {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [String: Any] else { return [:] }
        return object.compactMapValues { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
    }

    // MARK: Struttura comune

    /// Esegue `work` come lavoro della riunione: stato, testo parziale e pulizia finale sono gli stessi per tutti.
    private func begin(_ id: String, _ job: Job, _ work: @escaping () async throws -> Void,
                       onFailure: @escaping (Error) -> Void) {
        failures[id] = nil
        jobs[id] = job
        tasks[id] = Task { [self] in
            do { try await work() } catch { onFailure(error) }
            jobs[id] = nil
            partial[id] = nil
            tasks[id] = nil
        }
    }

    /// Raccoglie la risposta a pezzi, aggiornando `partial`; restituisce il testo finale.
    private func collect(_ id: String, _ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream {
            text = chunk
            partial[id] = chunk
        }
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }
}
