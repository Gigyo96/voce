import Foundation

/// I prompt della dettatura, dalla `PromptLibrary` (predefiniti o personalizzati dall'utente nella pagina Prompt).
enum Prompts {
    static func cleanup(profile: Profile, terms: [String], store: PromptStore = .shared) -> String {
        store.render(.cleanup, ["stile": profile.llmInstructions(store), "vocabolario": terms.joined(separator: ", ")])
    }

    static var command: String { PromptStore.shared.text(.command) }
}

/// Frasi d'esempio usate sia per spiegare le funzioni sia per «Prova», nella lingua dell'app.
enum AIExample {
    private static var english: Bool { Loc.language == "en" }
    static var spoken: String {
        english ? "um so let's meet on tuesday actually no wednesday at three and bring the laptop"
            : "ehm allora ci vediamo martedì anzi no mercoledì alle tre e porta il portatile"
    }
    static var rewritten: String {
        english ? "So, let's meet on Wednesday at three and bring the laptop."
            : "Allora, ci vediamo mercoledì alle tre e porta il portatile."
    }
    static var instruction: String { english ? "translate into Italian" : "traduci in inglese" }
    static var selection: String {
        english ? "See you tomorrow at three for the project review."
            : "Ci vediamo domani alle tre per la revisione del progetto."
    }
}
