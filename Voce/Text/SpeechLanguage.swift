import Foundation

/// Lingua in cui si detta (Generale › Lingua della dettatura). Parakeet riconosce da solo italiano, inglese e le altre
/// lingue europee: la scelta decide quali comandi vocali valgono ("a capo" o "new line") e il filtro dell'alfabeto.
enum SpeechLanguage: String, CaseIterable, Sendable {
    /// Italiano e inglese, anche mescolati nella stessa frase: valgono i comandi di entrambe le lingue.
    case auto
    case it
    case en

    var usesItalianCommands: Bool { self != .en }
    var usesEnglishCommands: Bool { self != .it }
}

/// I comandi vocali come vanno pronunciati, per mostrarli nell'interfaccia (le regole sono in `Rules`).
enum VoiceCommand {
    case newline, paragraph, send

    private var italian: String {
        switch self {
        case .newline: return "a capo"
        case .paragraph: return "nuovo paragrafo"
        case .send: return "invia"
        }
    }

    private var english: String {
        switch self {
        case .newline: return "new line"
        case .paragraph: return "new paragraph"
        case .send: return "send"
        }
    }

    /// Tra virgolette, secondo la lingua della dettatura: «a capo», «new line» oppure «a capo» / «new line».
    /// Virgolette della lingua dell'app: «» in italiano, “” in inglese.
    var spoken: String {
        let q: (String) -> String = Loc.language == "en" ? { "“\($0)”" } : { "«\($0)»" }
        switch Prefs.speech {
        case .it: return q(italian)
        case .en: return q(english)
        case .auto: return q(italian) + " / " + q(english)
        }
    }
}
