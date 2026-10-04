import Foundation
import Testing
@testable import Voce

// Livello 3 (§6.3): guardrail sull'output dell'LLM, client compatibile OpenAI, provider.

@Suite struct GuardrailTests {
    @Test func lengthRatio() {
        let input = "ciao come va oggi tutto bene"
        #expect(Guardrail.violation(input: input, output: "Ciao, come va oggi? Tutto bene.") == nil)
        #expect(Guardrail.violation(input: input, output: String(repeating: "lungo ", count: 20)) != nil)
        #expect(Guardrail.violation(input: input, output: "Ciao") != nil)
        #expect(Guardrail.violation(input: input, output: "") != nil)
    }

    @Test func assistantPreambles() {
        let input = "scrivi una funzione che somma due numeri"
        #expect(Guardrail.violation(input: input, output: "Certo! Ecco la funzione che somma") != nil)
        #expect(Guardrail.violation(input: input, output: "Sure, here is the function sum") != nil)
        #expect(Guardrail.violation(input: "ecco il piano di oggi", output: "Ecco il piano di oggi.") == nil)
    }

    @Test func answeringInsteadOfCleaning() {
        // Caso reale con gemma3:1b: lunghezza nei limiti, ma il modello ha eseguito la richiesta.
        let input = "Mi scrivi una funzione che ordina una lista in Python"
        #expect(Guardrail.violation(input: input, output: "def order_list():\n  pass") != nil)
        #expect(Guardrail.violation(input: "ci vediamo martedì anzi mercoledì alle tre per parlare di supabase",
                                    output: "Ci vediamo mercoledì alle tre per parlare di Supabase.") == nil)
    }

    @Test func cleansModelOutput() {
        #expect(Guardrail.clean("<think>\n\n</think>\n\nCiao, come va?") == "Ciao, come va?")
        #expect(Guardrail.clean("\"Ciao, come va?\"") == "Ciao, come va?")
        #expect(Guardrail.clean("```\nCiao\n```") == "Ciao")
    }

    @Test func maxTokens() {
        #expect(LLMClient.maxTokens(for: String(repeating: "a", count: 350)) == 150)
        #expect(LLMClient.maxTokens(for: "ciao") == 64)
    }

    @Test func noLLMMeansRulesAndDictionaryOnly() async {
        let dict = PersonalDictionary(terms: ["useEffect"], replace: [:])
        let out = await PostProcess.run(raw: "Ehm, aggiungi uno use effect.", profile: .agentIDE, dictionary: dict,
                                        sendOnInvia: false, llm: nil)
        #expect(out.text == "Aggiungi uno useEffect.")
        #expect(!out.llmUsed)
    }

    @Test func llmFailureFallsBackToRules() async {
        let dict = PersonalDictionary()
        let cfg = LLMConfig(baseURL: "http://127.0.0.1:9", model: "x", apiKey: nil, timeout: 0.5)
        let out = await PostProcess.run(raw: "ciao, ehm, come va", profile: .chat, dictionary: dict,
                                        sendOnInvia: false, llm: cfg)
        #expect(out.text == "Ciao, come va")
        #expect(!out.llmUsed)
        #expect(out.guardrail != nil)
    }

    @Test func endpointKeepsTheProviderVersion() {
        func url(_ base: String) -> String? { LLMClient.endpoint(base, "chat/completions")?.absoluteString }
        #expect(url("http://localhost:1234") == "http://localhost:1234/v1/chat/completions")
        #expect(url("http://localhost:11434/v1/") == "http://localhost:11434/v1/chat/completions")
        #expect(url("https://api.groq.com/openai") == "https://api.groq.com/openai/v1/chat/completions")
        #expect(url(LLMProvider.gemini.baseURL) == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(url(LLMProvider.openRouter.baseURL) == "https://openrouter.ai/api/v1/chat/completions")
    }

    /// Il corpo JSON di una richiesta `chat/completions` per un servizio e un modello.
    private func body(_ baseURL: String, _ model: String, maxTokens: Int = 64) throws -> [String: Any] {
        let cfg = LLMConfig(baseURL: baseURL, model: model, apiKey: "k", timeout: 1)
        let req = try LLMClient.chatRequest([.init(role: "user", content: "ciao")], config: cfg, temperature: 0,
                                            maxTokens: maxTokens, stream: false)
        return try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any] ?? [:]
    }

    @Test func openAIGetsMaxCompletionTokensAndDefaultTemperature() throws {
        let gpt = try body("https://api.openai.com/v1", "gpt-6-luna")
        #expect(gpt["max_tokens"] == nil)
        #expect(gpt["max_completion_tokens"] != nil)
        #expect(gpt["temperature"] == nil)   // i modelli che ragionano accettano solo quella predefinita
        let classic = try body("https://api.openai.com/v1", "gpt-4.1-mini")
        #expect(classic["max_completion_tokens"] as? Int == 64)
        #expect(classic["temperature"] as? Double == 0)
        let groq = try body("https://api.groq.com/openai", "llama-4-scout")
        #expect(groq["max_tokens"] as? Int == 64)
        #expect(groq["max_completion_tokens"] == nil)
    }

    @Test func reasoningModelsGetRoomToThink() throws {
        for (url, model) in [("https://api.groq.com/openai", "openai/gpt-oss-20b"),
                             ("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.5-flash-lite"),
                             ("https://openrouter.ai/api/v1", "openai/gpt-5-mini")] {
            let b = try body(url, model)
            #expect(b["reasoning_effort"] != nil, "\(model)")
            #expect((b["max_tokens"] as? Int ?? 0) == 64 + LLMClient.reasoningAllowance, "\(model)")
        }
        #expect(try body("http://localhost:11434", "qwen3:1.7b")["max_tokens"] as? Int == 64)
    }

    @Test func providerFromAddress() {
        #expect(LLMProvider.matching("http://127.0.0.1:11434/v1") == .ollama)
        #expect(LLMProvider.matching("http://localhost:1234") == .lmStudio)
        #expect(LLMProvider.matching("https://api.groq.com/openai/") == .groq)
        #expect(LLMProvider.matching("http://localhost:8080") == .custom)
        #expect(LLMProvider.matching("") == .custom)
        for p in LLMProvider.allCases where p != .custom { #expect(LLMProvider.matching(p.baseURL) == p) }
    }

    @Test @MainActor func ollamaLatestTag() {
        #expect(AIStatus.same("llama3.2:latest", "llama3.2"))
        #expect(!AIStatus.same("qwen3:1.7b", "qwen3:4b"))
    }
}

/// Integrazione con un server reale, solo su richiesta:
/// `VOCE_LLM_BASE=http://localhost:11434 VOCE_LLM_MODEL=gemma3:4b swift test --filter LLMIntegration`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOCE_LLM_BASE"] != nil))
struct LLMIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    @Test func chatCleanup() async {
        let cfg = LLMConfig(baseURL: env["VOCE_LLM_BASE"]!, model: env["VOCE_LLM_MODEL"] ?? "qwen3-1.7b",
                            apiKey: env["VOCE_LLM_KEY"], timeout: 30)
        let dict = PersonalDictionary(terms: ["Supabase", "useEffect"], replace: [:])
        let out = await PostProcess.run(raw: "ciao marco ci vediamo martedì anzi mercoledì per parlare di supabase",
                                        profile: .chat, dictionary: dict, sendOnInvia: false, llm: cfg)
        print("LLM \(out.llmMs ?? -1) ms, guardrail=\(out.guardrail ?? "-"): \(out.text)")
        #expect(out.llmUsed)
        #expect(out.text.contains("mercoledì"))
        #expect(out.text.contains("Supabase"))
    }
}
