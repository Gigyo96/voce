import Foundation

// MARK: - Pipeline completa di post-processing

struct PostProcessResult: Sendable {
    var text: String
    var send: Bool
    var llmUsed: Bool
    var guardrail: String?   // motivo per cui l'output LLM è stato scartato
    var llmMs: Int?
}

enum PostProcess {
    /// Regole + dizionario (sempre), poi LLM solo se il profilo lo prevede. Ogni errore ricade sull'output delle regole.
    static func run(raw: String, profile: Profile, dictionary: PersonalDictionary, sendOnInvia: Bool,
                    language: SpeechLanguage = .auto, llm: LLMConfig?) async -> PostProcessResult {
        let ruled = Rules.apply(raw, profile: profile, sendOnInvia: sendOnInvia, language: language)
        let base = Rules.tidy(dictionary.apply(ruled.text))
        var result = PostProcessResult(text: base, send: ruled.send, llmUsed: false)
        guard let llm, !base.isEmpty else { return result }

        let start = Date()
        do {
            let out = try await LLMClient.complete(
                system: Prompts.cleanup(profile: profile, terms: dictionary.terms),
                user: "TRASCRITTO: \(base)", config: llm, maxTokens: LLMClient.maxTokens(for: base))
            result.llmMs = Int(Date().timeIntervalSince(start) * 1000)
            if let why = Guardrail.violation(input: base, output: out) {
                result.guardrail = why
            } else {
                result.text = dictionary.apply(out)
                result.llmUsed = true
            }
        } catch {
            result.llmMs = Int(Date().timeIntervalSince(start) * 1000)
            result.guardrail = "errore: \(error.localizedDescription)"
        }
        return result
    }
}
