import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Voce

// Unico test (§9.3): regole + dizionario + guardrail.

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

@Suite struct BoostingArbitrationTests {
    let vocab = Transcriber.vocabulary(for: PersonalDictionary(
        terms: ["Supabase", "PostgreSQL", "Claude Code", "kubectl"], replace: ["cube cuttle": "kubectl"]))

    @Test func keepsPunctuationAndPrepositions() {
        // Casi reali dal rescorer di FluidAudio su audio italiano.
        let raw = "Leggi lo userid da super base, poi migra il database a PostgreSQL con Cloud Code e lancia CubeCutle."
        let pairs = [("super base,", "Supabase"), ("a PostgreSQL", "PostgreSQL"), ("database", "Supabase"),
                     ("Cloud Code", "Claude Code"), ("CubeCutle", "kubectl"), ("M, aggiungi uno", "Claude Code")]
            .map { (original: $0.0, term: $0.1) }
        #expect(Transcriber.applyReplacements(pairs, to: raw, vocabulary: vocab)
            == "Leggi lo userid da Supabase, poi migra il database a PostgreSQL con Claude Code e lancia kubectl.")
    }

    @Test func similarity() {
        #expect(Transcriber.similarity("supabase", "supabase") == 1)
        #expect(Transcriber.similarity("database", "supabase") < Transcriber.minSimilarity)
        #expect(Transcriber.similarity("cloudcode", "claudecode") >= Transcriber.minSimilarity)
    }
}

@Suite struct SegmenterTests {
    @Test func cutsInTheQuietestPoint() {
        // 16 s di "voce" con una pausa a 10 s: il taglio deve cadere nella pausa.
        var s = (0..<(16 * 16_000)).map { i in Float(sin(Double(i) * 0.05)) * 0.3 }
        for i in (10 * 16_000)..<(10 * 16_000 + 4_000) { s[i] = 0 }
        let cut = Segmenter.cutPoint(s)
        #expect(cut >= 10 * 16_000 && cut <= 10 * 16_000 + 4_000)
    }

    @Test func joinsSegments() {
        #expect(Segmenter.join(["Prima parte senza punto", "Seconda parte.", "Terza."]) == "Prima parte senza punto seconda parte. Terza.")
        #expect(Segmenter.join(["Usa la", "API di Groq", ""]) == "Usa la API di Groq")
    }
}

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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
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

@Suite @MainActor struct HotkeyTests {
    /// ⌘ destro premuto (0x10 = bit del lato destro) o rilasciato.
    private func rightCommand(_ down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(54), keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10) : []
        return e
    }

    @Test func spaceWhileHoldingSwitchesToHandsFree() {
        let hk = Hotkey()
        var events: [String] = []
        hk.onStart = { events.append("start \($0)") }
        hk.onModeChange = { events.append("mode \($0)") }
        hk.onStop = { events.append("stop") }
        hk.onCancel = { events.append("cancel") }

        _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
        let space = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(49), keyDown: true)!
        #expect(hk.handle(type: .keyDown, event: space))          // lo Spazio non arriva all'app
        _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        #expect(events == ["start pushToTalk", "mode handsFree"])  // il rilascio non chiude
        _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
        _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        #expect(events.last == "stop")
    }

    @Test func doubleTapOnlyWhenChosen() {
        let hk = Hotkey()
        var starts: [String] = []
        hk.onStart = { starts.append("\($0)") }
        for _ in 0..<2 {
            _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
            _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        }
        #expect(!starts.contains("handsFree"))   // default .space: il doppio tocco resta a Siri
    }

    @Test func functionKeyTriggerIsSwallowedAndHeld() {
        let hk = Hotkey()
        hk.trigger = Hotkey.Trigger(kVK_F5)
        var events: [String] = []
        hk.onStart = { events.append("start \($0)") }
        hk.onStop = { events.append("stop") }
        let f5 = { (down: Bool) in CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_F5), keyDown: down)! }
        #expect(hk.handle(type: .keyDown, event: f5(true)))
        #expect(hk.handle(type: .keyDown, event: f5(true)))      // autoripetizione: nessun secondo start
        Thread.sleep(forTimeInterval: Hotkey.minHold)
        #expect(hk.handle(type: .keyUp, event: f5(false)))
        #expect(events == ["start pushToTalk", "stop"])
    }

    @Test func recordsModifierOnReleaseAndKeyOnPress() {
        let hk = Hotkey()
        var got: Hotkey.Trigger?
        hk.record { got = $0 }
        _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
        #expect(got == nil)
        _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        #expect(got == .rightCommand)

        hk.record { got = $0 }
        let space = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true)!
        space.flags = [.maskControl, .maskAlternate]
        #expect(hk.handle(type: .keyDown, event: space))
        #expect(got == Hotkey.Trigger(kVK_Space, [.maskControl, .maskAlternate]))
    }
}

@Suite struct TriggerTests {
    typealias T = Hotkey.Trigger

    @Test func prefRoundTripKeepsLegacyNames() {
        #expect(T(rawValue: "rightCommand") == .rightCommand)
        #expect(T.rightOption.rawValue == "rightOption")
        let combo = T(kVK_Space, [.maskControl, .maskAlternate, .maskSecondaryFn])   // Fn non conta
        #expect(T(rawValue: combo.rawValue) == combo)
        #expect(combo.flags == [.maskControl, .maskAlternate])
        #expect(T(rawValue: "garbage") == nil)
    }

    @Test func commandModifierNeverClashesWithTheTrigger() {
        #expect(T.rightCommand.commandModifier == .maskShift)
        #expect(T.fn.commandModifier == .maskCommand)
        #expect(T(kVK_F5).commandModifier == .maskCommand)
        #expect(T(kVK_Space, [.maskCommand, .maskShift]).commandModifier == .maskAlternate)
    }

    @Test func rejectsKeysThatType() {
        #expect(T(kVK_ANSI_A).problem != nil)
        #expect(T(kVK_Space, .maskAlternate).problem != nil)    // ⌥Spazio scrive uno spazio unificatore
        #expect(T(kVK_CapsLock).problem != nil)
        #expect(T(kVK_Space, [.maskControl, .maskAlternate]).problem == nil)
        #expect(T(kVK_F13).problem == nil)
        #expect(T(0xB0).problem == nil)                          // 🎤
        #expect(T(kVK_Option).problem == nil)
    }

    @Test func modifierStateWithAndWithoutSideBits() {
        let rightCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        #expect(Keys.isPressed(kVK_RightCommand, rightCmd))
        #expect(!Keys.isPressed(kVK_Command, rightCmd))
        // Tastiera che non imposta i bit del lato: vale il flag generico.
        #expect(Keys.isPressed(kVK_RightOption, .maskAlternate))
        #expect(!Keys.isPressed(kVK_RightOption, []))
    }
}
