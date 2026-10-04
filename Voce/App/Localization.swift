import Foundation

// MARK: - Lingua dell'app

/// Lingua dell'interfaccia, scelta in Generale › Lingua dell'app. `system` segue le preferenze di macOS
/// (italiano se è la lingua preferita, altrimenti inglese).
enum AppLanguage: String, CaseIterable, Sendable {
    case system, it, en

    /// Lingua effettiva: "it" o "en".
    var resolved: String {
        switch self {
        case .it, .en: return rawValue
        case .system:
            let preferred = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier }
            return preferred == "it" ? "it" : "en"
        }
    }

    static var current: AppLanguage { AppLanguage(rawValue: Prefs.appLanguage.value) ?? .system }

    /// Fa seguire la scelta anche ai testi forniti da macOS (menu, avvisi, richiesta del microfono) dal prossimo avvio.
    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Traduzioni dal String Catalog `Voce/Resources/Localizable.xcstrings` (lingua sorgente: italiano).
///
/// Il catalogo si legge a runtime invece di compilarlo con Xcode: così la lingua cambia subito, senza riavvio,
/// e non serve `Bundle.module` (che in una .app assemblata da `scripts/build.sh` non troverebbe le risorse).
/// La chiave è il testo italiano: se una traduzione manca si vede l'italiano, mai una chiave tecnica.
enum Loc {
    /// Testo italiano → traduzione inglese.
    static let english: [String: String] = load(catalogURL)

    static var language: String { AppLanguage.current.resolved }
    static var locale: Locale { Locale(identifier: language == "it" ? "it_IT" : "en_US") }

    static func string(_ key: String) -> String {
        language == "en" ? english[key] ?? key : key
    }

    /// Nell'app il catalogo sta in Contents/Resources; da `swift run` e nei test si legge dai sorgenti.
    static var catalogURL: URL {
        if let url = Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings") { return url }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../Resources/Localizable.xcstrings").standardizedFileURL
    }

    static func load(_ url: URL) -> [String: String] {
        struct Catalog: Decodable {
            struct Entry: Decodable { let localizations: [String: Localization]? }
            struct Localization: Decodable { let stringUnit: Unit? }
            struct Unit: Decodable { let value: String }
            let strings: [String: Entry]
        }
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            NSLog("Voce: catalogo delle traduzioni non trovato in \(url.path)")
            return [:]
        }
        return catalog.strings.compactMapValues { $0.localizations?["en"]?.stringUnit?.value }
    }
}

/// Testo dell'interfaccia nella lingua dell'app. La chiave è la frase italiana.
func L(_ key: String) -> String { Loc.string(key) }

/// Come `L(_:)`, con segnaposto in stile `String(format:)`: `L("Pronto · tieni premuto %@", tasto)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Loc.string(key), locale: Loc.locale, arguments: args)
}
