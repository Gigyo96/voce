import Foundation
import Testing
@testable import Voce

// Livelli 1 e 2 del post-processing (§6.1, §6.2): regole deterministiche, profili, dizionario personale.

@Suite struct RulesTests {
    @Test func removesFillers() {
        let out = Rules.apply("Ehm, allora, uhm aggiungi un test eh per il parser.", profile: .plain, sendOnInvia: false)
        #expect(out.text == "Allora, aggiungi un test per il parser.")
    }

    @Test func keepsWordsContainingFillers() {
        let out = Rules.apply("Il tema è umido e uhm il mmap funziona.", profile: .plain, sendOnInvia: false)
        #expect(out.text == "Il tema è umido e il mmap funziona.")
    }

    @Test func newlineAndParagraph() {
        let out = Rules.apply("Prima riga. A capo. seconda riga, nuovo paragrafo, terza.", profile: .plain, sendOnInvia: false)
        #expect(out.text == "Prima riga.\nSeconda riga\n\nTerza.")
    }

    @Test func aCapoDelIsNotACommand() {
        let out = Rules.apply("Marco è a capo del progetto.", profile: .plain, sendOnInvia: false)
        #expect(out.text == "Marco è a capo del progetto.")
    }

    @Test func inviaOnlyWhenEnabledOnAgentsAtTheEnd() {
        let text = "Esegui i test e correggi gli errori, invia."
        #expect(Rules.apply(text, profile: .agentTerminal, sendOnInvia: true) == RulesOutput(text: "Esegui i test e correggi gli errori", send: true))
        #expect(Rules.apply(text, profile: .agentTerminal, sendOnInvia: false).send == false)
        #expect(Rules.apply(text, profile: .chat, sendOnInvia: true).send == false)
        #expect(Rules.apply("Invia la mail a Marco.", profile: .agentIDE, sendOnInvia: true).send == false)
    }

    @Test func parakeetHesitationAsSingleM() {
        // Parakeet trascrive spesso "ehm" come "M,".
        let out = Rules.apply("M, aggiungi uno use effect. Sono 5 m di cavo.", profile: .plain, sendOnInvia: false)
        #expect(out.text == "Aggiungi uno use effect. Sono 5 m di cavo.")
    }

    @Test func profiles() {
        #expect(Profile.from(bundleID: "com.todesktop.230313mzl4w4u92") == .agentIDE)
        #expect(Profile.from(bundleID: "com.mitchellh.ghostty") == .agentTerminal)
        #expect(Profile.from(bundleID: "com.apple.mail") == .email)
        #expect(Profile.from(bundleID: "com.example.unknown") == .plain)
        #expect(Profile.agentTerminal.newlineKey == "shift+return")
        #expect(Profile.chat.usesLLM("chat,email"))
        #expect(!Profile.agentIDE.usesLLM("chat,email"))
        #expect(Profile.agentIDE.usesLLM("chat, agentIDE"))
    }
}

@Suite struct DictionaryTests {
    let dict = PersonalDictionary(
        terms: ["Claude Code", "useEffect", "PostgreSQL", "Next.js", "user_id", "kubectl"],
        replace: ["cube cuttle": "kubectl", "postgres q l": "PostgreSQL"])

    @Test func spokenForms() {
        #expect(PersonalDictionary.spokenForms(of: "useEffect") == ["useEffect", "use Effect", "useEffect"].uniqued())
        #expect(PersonalDictionary.spokenForms(of: "PostgreSQL").contains("Postgre SQL"))
        #expect(PersonalDictionary.spokenForms(of: "user_id").contains("user id"))
        #expect(PersonalDictionary.spokenForms(of: "Next.js").contains("Next js"))
        #expect(PersonalDictionary.spokenForms(of: "next-auth").contains("next auth"))
    }

    @Test func replacesSpokenForms() {
        #expect(dict.apply("Aggiungi uno use effect che legge lo user id.") == "Aggiungi uno useEffect che legge lo user_id.")
        #expect(dict.apply("Usa Use-Effect e useeffect") == "Usa useEffect e useEffect")
        #expect(dict.apply("Apri claude code e lancia cube cuttle.") == "Apri Claude Code e lancia kubectl.")
        #expect(dict.apply("Migra a Postgres Q L con next js.") == "Migra a PostgreSQL con Next.js.")
    }

    @Test func wordBoundariesOnly() {
        let d = PersonalDictionary(terms: ["React"], replace: [:])
        #expect(d.apply("reactivity e react") == "reactivity e React")
    }

    @Test func singlePassNoChains() {
        let d = PersonalDictionary(terms: [], replace: ["a b": "c d", "c d": "x"])
        #expect(d.apply("a b") == "c d")
    }

    @Test func decodesPartialJSON() throws {
        let d = try JSONDecoder().decode(PersonalDictionary.self, from: Data(#"{"terms":["Supabase"]}"#.utf8))
        #expect(d.terms == ["Supabase"])
        #expect(d.replace.isEmpty)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
