import Foundation

struct LLMConfig: Sendable {
    var baseURL: String
    var model: String
    var apiKey: String?
    var timeout: TimeInterval
}

enum LLMError: LocalizedError {
    case badURL, http(Int, String), empty
    var errorDescription: String? {
        switch self {
        case .badURL: return L("URL LLM non valido")
        case .http(let code, let body): return L("Errore HTTP %ld del servizio AI: %@", code, String(body.prefix(200)))
        case .empty: return L("Risposta LLM vuota")
        }
    }
}

/// Un solo client verso `POST {baseURL}/v1/chat/completions` (LM Studio, Ollama, Groq…).
enum LLMClient {
    struct Message: Codable, Sendable {
        let role: String
        let content: String
        init(role: String, content: String) { self.role = role; self.content = content }
    }
    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
        let reasoning_effort: String?
    }
    private struct Response: Decodable {
        struct Choice: Decodable { let message: Message }
        let choices: [Choice]
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Stima grezza: ~3,5 caratteri per token. `max_tokens` = 1,3 × input + 20 (§5).
    static func maxTokens(for input: String, floor: Int = 64) -> Int {
        max(floor, Int(Double(input.count) / 3.5 * 1.3) + 20)
    }

    /// `{baseURL}/v1/<path>`, oppure `{baseURL}/<path>` se l'indirizzo contiene già una versione
    /// (`…/v1`, Gemini `…/v1beta/openai`). Così vanno bene sia `http://localhost:1234` sia gli URL dei provider.
    static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let versioned = URL(string: base)?.pathComponents.contains { $0.range(of: #"^v\d+(alpha|beta)?\d*$"#, options: .regularExpression) != nil } ?? false
        return URL(string: base + (versioned ? "/" : "/v1/") + path)
    }

    /// Modelli che ragionano prima di rispondere: per sistemare un testo basta il minimo.
    static func reasoningEffort(model: String) -> String? {
        let m = model.lowercased()
        if m.contains("gpt-oss") { return "low" }
        if m.contains("luna") { return "none" }
        if m.hasPrefix("gpt-6") || m.hasPrefix("gemini") { return "low" }
        return nil
    }

    private static func authorize(_ req: inout URLRequest, _ config: LLMConfig) {
        guard let key = config.apiKey, !key.isEmpty else { return }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if req.url?.host() == "api.anthropic.com" {   // l'elenco dei modelli è l'API nativa
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    /// Richiesta a `chat/completions`; per i modelli Qwen3 il ragionamento si disattiva (§5).
    private static func chatRequest(_ messages: [Message], config: LLMConfig, temperature: Double, maxTokens: Int,
                                    stream: Bool) throws -> URLRequest {
        guard let url = endpoint(config.baseURL, "chat/completions") else { throw LLMError.badURL }
        let model = config.model.lowercased()
        var messages = messages
        if model.contains("qwen3"), let i = messages.firstIndex(where: { $0.role == "system" }) {
            messages[i] = Message(role: "system", content: messages[i].content + "\n/no_think")
        }
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req, config)
        req.httpBody = try JSONEncoder().encode(Request(
            model: config.model, messages: messages, temperature: temperature, max_tokens: maxTokens, stream: stream,
            reasoning_effort: reasoningEffort(model: model)))
        return req
    }

    static func complete(system: String, user: String, config: LLMConfig, maxTokens: Int) async throws -> String {
        let request = try chatRequest([Message(role: "system", content: system), Message(role: "user", content: user)],
                                      config: config, temperature: 0, maxTokens: maxTokens, stream: false)
        let (data, resp) = try await withTimeout(config.timeout) { try await session.data(for: request) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        let text = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        let cleaned = Guardrail.clean(text)
        guard !cleaned.isEmpty else { throw LLMError.empty }
        return cleaned
    }

    /// Conversazione a più turni con la risposta a pezzi (SSE): ogni elemento è il testo *accumulato finora*, già
    /// ripulito dei blocchi <think>. `config.timeout` è l'attesa massima tra un pezzo e il successivo, non la durata totale.
    static func stream(_ messages: [Message], config: LLMConfig, maxTokens: Int = 2048,
                       temperature: Double = 0.3) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try chatRequest(messages, config: config, temperature: temperature, maxTokens: maxTokens, stream: true)
                    let (bytes, resp) = try await session.bytes(for: request)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 400 { break } }
                        throw LLMError.http(code, body)
                    }
                    var text = ""
                    for try await line in bytes.lines {
                        guard let delta = delta(inSSELine: line) else { continue }
                        text += delta
                        continuation.yield(Guardrail.visible(text))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Il testo di una riga `data: {...}` di una risposta in streaming; `nil` per righe vuote, commenti e `[DONE]`.
    static func delta(inSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        struct Chunk: Decodable {
            struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta? }
            let choices: [Choice]?
        }
        return (try? JSONDecoder().decode(Chunk.self, from: data))?.choices?.first?.delta?.content
    }

    /// `GET {baseURL}/v1/models`: verifica indirizzo e chiave senza consumare token e dà l'elenco per la scelta del modello.
    static func models(config: LLMConfig) async throws -> [String] {
        guard let url = endpoint(config.baseURL, "models") else { throw LLMError.badURL }
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        authorize(&req, config)
        let request = req
        let (data, resp) = try await withTimeout(config.timeout) { try await session.data(for: request) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(decoding: data, as: UTF8.self)) }
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let skip = ["embed", "whisper", "tts", "audio", "transcribe", "image", "imagen", "veo", "dall-e", "sora",
                    "moderation", "guard", "safeguard", "orpheus", "rerank", "bge"]
        return (try JSONDecoder().decode(List.self, from: data)).data
            .map { $0.id.hasPrefix("models/") ? String($0.id.dropFirst(7)) : $0.id }   // Gemini
            .filter { id in !skip.contains { id.lowercased().contains($0) } }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Versione breve per il HUD (una riga): i dettagli sono in Funzioni AI → Prova.
    static func headline(_ error: Error) -> String {
        if error is TimeoutError { return L("il servizio AI non ha risposto in tempo") }
        if error is URLError { return L("servizio AI non raggiungibile") }
        switch error as? LLMError {
        case .http(let code, _) where code == 401 || code == 403: return L("chiave del servizio AI non valida")
        case .http(404, _): return L("modello AI non trovato")
        case .http(429, _): return L("limite di richieste raggiunto")
        default: return L("errore del servizio AI")
        }
    }

    /// Errori di rete tradotti in qualcosa di azionabile.
    static func friendly(_ error: Error) -> String {
        if error is TimeoutError { return L("Nessuna risposta in tempo: il servizio è avviato? Prova ad aumentare l'attesa massima.") }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost:
                return L("Il servizio non risponde: se è sul Mac, apri LM Studio o Ollama e controlla che il server sia avviato.")
            case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
                return L("Servizio non raggiungibile: controlla l'indirizzo e la connessione a internet.")
            case .timedOut:
                return L("Nessuna risposta in tempo: il servizio è avviato?")
            default: break
            }
        }
        switch error as? LLMError {
        case .badURL: return L("Indirizzo del servizio non valido.")
        case .empty: return L("Il modello ha risposto con un testo vuoto.")
        case .http(let code, _) where code == 401 || code == 403: return L("La chiave non è valida o manca.")
        case .http(404, _): return L("Indirizzo o modello non trovato: controlla il nome del modello.")
        case .http(429, _): return L("Limite di richieste del servizio raggiunto: riprova tra poco o controlla il tuo piano.")
        case .http(let code, _) where code >= 500: return L("Il servizio ha un problema (errore %ld): riprova più tardi.", code)
        default: return error.localizedDescription
        }
    }
}

struct TimeoutError: LocalizedError { var errorDescription: String? { "timeout" } }

/// Timeout duro: `URLRequest.timeoutInterval` è un timeout di inattività, non di durata totale.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
