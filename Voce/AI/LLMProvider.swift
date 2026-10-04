import Foundation

// MARK: - Servizi AI: un solo client compatibile OpenAI (§6.3), molti provider

/// Provider noti: scegliendone uno si compilano indirizzo e modello. Modelli predefiniti verificati a ottobre 2026
/// (Groq ha spento llama-3.1-8b-instant il 16/08/2026). L'elenco reale arriva comunque da `GET /v1/models`.
enum LLMProvider: String, CaseIterable, Identifiable {
    case lmStudio, ollama, groq, cerebras, gemini, anthropic, openAI, openRouter, custom
    var id: String { rawValue }

    static let onMac: [LLMProvider] = [.lmStudio, .ollama]
    static let online: [LLMProvider] = [.groq, .cerebras, .gemini, .anthropic, .openAI, .openRouter]

    var name: String {
        switch self {
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        case .groq: return "Groq"
        case .cerebras: return "Cerebras"
        case .gemini: return "Google Gemini"
        case .anthropic: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .custom: return L("Altro servizio compatibile OpenAI…")
        }
    }

    var baseURL: String {
        switch self {
        case .lmStudio: return "http://localhost:1234"
        case .ollama: return "http://localhost:11434"
        case .groq: return "https://api.groq.com/openai"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    /// Per la riscrittura: piccolo e veloce, deve solo sistemare il testo.
    var model: String {
        switch self {
        case .lmStudio: return "qwen3-1.7b"
        case .ollama: return "qwen3:1.7b"
        case .groq, .openRouter: return "openai/gpt-oss-20b"
        case .cerebras: return "gpt-oss-120b"
        case .gemini: return "gemini-3.5-flash-lite"
        case .anthropic: return "claude-haiku-4-5"
        case .openAI: return "gpt-6-luna"
        case .custom: return ""
        }
    }

    /// Per i comandi: più capace, qui qualche decimo di secondo in più si accetta.
    var commandModel: String {
        switch self {
        case .lmStudio: return "qwen3-4b"
        case .ollama: return "qwen3:4b"
        case .groq, .openRouter: return "openai/gpt-oss-120b"
        case .gemini: return "gemini-3.8-flash"
        default: return model
        }
    }

    /// Dove si crea la chiave (online) o si scarica l'app (sul Mac).
    var setupURL: URL? {
        switch self {
        case .lmStudio: return URL(string: "https://lmstudio.ai")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .cerebras: return URL(string: "https://cloud.cerebras.ai")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .custom: return nil
        }
    }

    /// Markdown: cosa costa, dove va il testo, cosa fare per iniziare.
    var blurb: String {
        switch self {
        case .lmStudio:
            return L("Gratis e privato: il testo non esce dal Mac. In LM Studio scarica un modello (per esempio Qwen3 1.7B) e avvia il server. [Scarica LM Studio](https://lmstudio.ai)")
        case .ollama:
            return L("Gratis e privato: il testo non esce dal Mac. Dopo l'installazione scarica un modello, per esempio con `ollama pull qwen3:1.7b`. [Scarica Ollama](https://ollama.com/download)")
        case .groq: return L("Molto veloce, con un piano gratuito che basta per l'uso personale. Il testo viene inviato a Groq.")
        case .cerebras: return L("Il più veloce, con un piano gratuito. Il testo viene inviato a Cerebras.")
        case .gemini: return L("Piano gratuito con una chiave di Google AI Studio (in quel piano Google può usare i testi per migliorare i modelli). Il testo viene inviato a Google.")
        case .anthropic: return L("A consumo, ottimo per i comandi più complessi. Il testo viene inviato ad Anthropic.")
        case .openAI: return L("A consumo. Il testo viene inviato a OpenAI.")
        case .openRouter: return L("Una sola chiave per centinaia di modelli di provider diversi, a consumo.")
        case .custom: return L("Qualsiasi servizio con un'API compatibile OpenAI (vLLM, llama.cpp, Mistral, Together…).")
        }
    }

    /// Riconosce il provider da host e porta, così anche `http://127.0.0.1:11434/v1` è Ollama.
    static func matching(_ url: String) -> LLMProvider {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), var host = u.host()?.lowercased() else { return .custom }
        if host == "127.0.0.1" { host = "localhost" }
        return allCases.first { p in
            guard p != .custom, let b = URL(string: p.baseURL) else { return false }
            return b.host() == host && b.port == u.port
        } ?? .custom
    }

    /// "Groq · openai/gpt-oss-20b"
    static func describe(_ baseURL: String, _ model: String) -> String {
        let p = matching(baseURL)
        let name = p == .custom ? (URL(string: baseURL)?.host() ?? baseURL) : p.name
        return model.isEmpty ? name : "\(name) · \(model)"
    }
}
