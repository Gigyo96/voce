import Foundation

// MARK: - Stato dei servizi (raggiungibile? chiave valida? modello presente?)

@MainActor final class AIStatus: ObservableObject {
    static let shared = AIStatus()

    enum State: Equatable { case unknown, checking, ok, failed(String) }

    @Published private(set) var main: State = .unknown
    @Published private(set) var command: State = .unknown
    /// Modelli offerti da ciascun servizio (chiave: `key(baseURL)`), letti all'ultimo controllo.
    @Published private(set) var models: [String: [String]] = [:]

    private var task: Task<Void, Never>?
    private var signature = ""
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentSignature != self.signature else { return }
                self.refresh()
            }
        }
    }

    private var currentSignature: String {
        [Prefs.llmBaseURL, Prefs.llmModel, Prefs.commandBaseURL, Prefs.commandModel].map(\.value).joined(separator: "|")
    }

    /// Controllo leggero (`GET /models`, nessun token consumato). Il ritardo evita una richiesta per ogni tasto premuto.
    func refresh(delay: Duration = .milliseconds(500)) {
        signature = currentSignature
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if main == .unknown { main = .checking }
            let m = await check(Prefs.llm())
            guard !Task.isCancelled else { return }
            main = m
            if Prefs.commandHasOwnService {
                let c = await check(Prefs.llm(command: true))
                guard !Task.isCancelled else { return }
                command = c
            } else {
                command = m
            }
        }
    }

    static func key(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
    }

    /// Ollama: "llama3.2" e "llama3.2:latest" sono lo stesso modello.
    static func same(_ a: String, _ b: String) -> Bool {
        func n(_ s: String) -> String {
            let l = s.lowercased().trimmingCharacters(in: .whitespaces)
            return l.hasSuffix(":latest") ? String(l.dropLast(7)) : l
        }
        return n(a) == n(b)
    }

    private func check(_ cfg: LLMConfig) async -> State {
        if cfg.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return .failed("Manca l'indirizzo del servizio.") }
        if !Prefs.isLocal(cfg.baseURL), (cfg.apiKey ?? "").isEmpty { return .failed("Manca la chiave API del servizio.") }
        var probe = cfg
        probe.timeout = 6
        do {
            let list = try await LLMClient.models(config: probe)
            models[Self.key(cfg.baseURL)] = list
            let model = cfg.model.trimmingCharacters(in: .whitespaces)
            if model.isEmpty { return .failed("Scegli un modello.") }
            if !list.isEmpty, !list.contains(where: { Self.same($0, model) }) {
                return .failed("Il modello «\(model)» non c'è in questo servizio: scegline uno dall'elenco.")
            }
            return .ok
        } catch LLMError.http(404, _) {
            return .ok   // servizio che non elenca i modelli: lo verifica solo «Prova»
        } catch {
            return .failed(LLMClient.friendly(error))
        }
    }
}
