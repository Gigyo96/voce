import Foundation
import SwiftUI

// MARK: - Impostazioni (§8)

/// Una preferenza in `UserDefaults`: nome e valore predefinito stanno in un solo posto.
/// Nel codice: `Prefs.sounds.value`; nelle viste: `@AppStorage(Prefs.sounds) private var sounds`.
/// Il predefinito vale per entrambi, quindi non serve `UserDefaults.register(defaults:)`.
struct Pref<Value: Sendable>: Sendable {
    let key: String
    let defaultValue: Value

    init(_ key: String, _ defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var value: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum Prefs {
    // Dettatura
    static let hotkey = Pref("hotkey", Hotkey.Trigger.rightCommand.rawValue)
    static let handsFree = Pref("handsFree", Hotkey.HandsFree.space.rawValue)
    static let sendOnInvia = Pref("sendOnInvia", false)
    static let maxRecordingSec = Pref("maxRecordingSec", 300)
    static let silenceRMS = Pref("silenceRMS", 0.008)
    static let sounds = Pref("sounds", false)
    static let welcomed = Pref("welcomed", false)

    // Microfono e riconoscimento
    static let warmMic = Pref("warmMic", false)
    static let asrModel = Pref("asrModel", Transcriber.Model.ultra.rawValue)
    static let vocabBoost = Pref("vocabBoost", true)                // boosting CTC del dizionario (~+115 ms su M2)

    // Inserimento
    // ponytail: attesa fissa; le app Electron/Chrome leggono gli appunti in ritardo sotto carico
    static let restoreClipboardMs = Pref("restoreClipboardMs", 600)
    static let saveSamples = Pref("saveSamples", false)

    // Servizi AI: riscrittura e comandi sul testo selezionato
    static let llmBaseURL = Pref("llmBaseURL", "http://localhost:1234")
    static let llmModel = Pref("llmModel", "qwen3-1.7b")
    static let llmTimeoutMs = Pref("llmTimeoutMs", 1500)
    static let llmProfiles = Pref("llmProfiles", "chat,email")
    static let commandBaseURL = Pref("commandBaseURL", "")         // vuoto = come llmBaseURL
    static let commandModel = Pref("commandModel", "")             // vuoto = come llmModel
    static let commandTimeoutMs = Pref("commandTimeoutMs", 6000)

    // MARK: Valori già interpretati

    static var trigger: Hotkey.Trigger { Hotkey.Trigger(rawValue: hotkey.value) ?? .rightCommand }
    static var handsFreeMode: Hotkey.HandsFree { Hotkey.HandsFree(rawValue: handsFree.value) ?? .space }
    static var model: Transcriber.Model { Transcriber.Model(rawValue: asrModel.value) ?? .ultra }

    /// Termini del dizionario da cercare nell'audio (vuoto se il boosting è spento).
    static func boostTerms(_ dictionary: PersonalDictionary) -> [(term: String, aliases: [String])] {
        vocabBoost.value ? Transcriber.vocabulary(for: dictionary) : []
    }

    static func llm(command: Bool = false) -> LLMConfig {
        var cfg = LLMConfig(baseURL: llmBaseURL.value, model: llmModel.value, apiKey: nil,
                            timeout: Double(llmTimeoutMs.value) / 1000)
        if command {
            if !commandBaseURL.value.isEmpty { cfg.baseURL = commandBaseURL.value }
            if !commandModel.value.isEmpty { cfg.model = commandModel.value }
            cfg.timeout = Double(commandTimeoutMs.value) / 1000
        }
        if !isLocal(cfg.baseURL) { cfg.apiKey = Keychain.apiKey(for: cfg.baseURL) }
        return cfg
    }

    /// I comandi usano un servizio diverso da quello della riscrittura.
    static var commandHasOwnService: Bool { !commandBaseURL.value.isEmpty || !commandModel.value.isEmpty }

    /// Una volta per avvio: chiave unica → chiave per servizio; modelli Groq dismessi il 16/08/2026.
    static func migrate() {
        let retired = ["llama-3.1-8b-instant": "openai/gpt-oss-20b", "llama-3.3-70b-versatile": "openai/gpt-oss-120b"]
        for pref in [llmModel, commandModel] {
            if let new = retired[pref.value] { pref.value = new }
        }
        Keychain.migrateLegacy(to: [llmBaseURL.value, commandBaseURL.value])
    }

    static func isLocal(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host() else { return true }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }
}

// MARK: - @AppStorage con una `Pref`

extension AppStorage {
    init(_ pref: Pref<Value>) where Value == String { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value == Bool { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value == Int { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value == Double { self.init(wrappedValue: pref.defaultValue, pref.key) }
}
