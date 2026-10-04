import Foundation

// MARK: - Livello 2: dizionario personale (§6.2)

struct PersonalDictionary: Codable, Equatable, Sendable {
    var terms: [String] = []
    var replace: [String: String] = [:]

    init(terms: [String] = [], replace: [String: String] = [:]) {
        self.terms = terms
        self.replace = replace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        replace = try c.decodeIfPresent([String: String].self, forKey: .replace) ?? [:]
    }

    static let example = PersonalDictionary(
        terms: ["Claude Code", "Supabase", "useEffect", "kubectl", "PostgreSQL", "Next.js"],
        replace: ["cube cuttle": "kubectl", "postgres q l": "PostgreSQL"]
    )

    /// Forme parlate generate dai termini: camelCase, snake_case, kebab-case, punti → parole separate,
    /// più la forma tutta attaccata ("useeffect"). Ogni termine corregge anche le proprie maiuscole.
    static func spokenForms(of term: String) -> [String] {
        var spaced = term.replacingOccurrences(of: #"([\p{Ll}\p{N}])(\p{Lu})"#, with: "$1 $2", options: .regularExpression)
        spaced = spaced.replacingOccurrences(of: #"(\p{Lu})(\p{Lu}\p{Ll})"#, with: "$1 $2", options: .regularExpression)
        spaced = spaced.replacingOccurrences(of: #"[_\-./]+"#, with: " ", options: .regularExpression)
        spaced = spaced.split(separator: " ").joined(separator: " ")
        let joined = spaced.replacingOccurrences(of: " ", with: "")
        var forms = [term]
        for f in [spaced, joined] where !forms.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) && !f.isEmpty {
            forms.append(f)
        }
        return forms
    }

    /// Tabella forma parlata (minuscola, spazi singoli) → forma scritta. Le voci di `replace` vincono.
    var replacementTable: [String: String] {
        var table: [String: String] = [:]
        for term in terms {
            for form in Self.spokenForms(of: term) { table[Self.key(form)] = term }
        }
        for (spoken, written) in replace { table[Self.key(spoken)] = written }
        return table
    }

    static func key(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Match esatto, case-insensitive, a confini di parola, in un solo passaggio (le sostituzioni non si rincorrono).
    func apply(_ text: String) -> String {
        let table = replacementTable
        guard !table.isEmpty else { return text }
        let alternatives = table.keys.sorted { $0.count > $1.count }.map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"[\s\-]+"#)
        }
        let pattern = #"(?<![\p{L}\p{N}_])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var out = ""
        var last = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let matched = String(text[r])
            let normalized = Self.key(matched.replacingOccurrences(of: "-", with: " "))
            out += text[last..<r.lowerBound]
            out += table[normalized] ?? table[Self.key(matched)] ?? matched
            last = r.upperBound
        }
        out += text[last...]
        return out
    }

    /// Legge `~/.voce/dictionary.json`; se manca lo crea con l'esempio del documento.
    static func load() -> PersonalDictionary {
        do { return try read() } catch {
            NSLog("Voce: dictionary.json non valido: \(error)")
            return PersonalDictionary()
        }
    }

    /// Come `load()`, ma un file illeggibile è un errore: l'editor non deve sovrascriverlo con un dizionario vuoto.
    static func read() throws -> PersonalDictionary {
        if !FileManager.default.fileExists(atPath: Paths.dictionary.path) { try example.save() }
        return try JSONDecoder().decode(PersonalDictionary.self, from: Data(contentsOf: Paths.dictionary))
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.dictionary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: Paths.dictionary, options: .atomic)
    }
}

/// Ricarica il dizionario solo quando il file cambia (controllo della data di modifica a ogni dettatura).
@MainActor final class DictionaryStore {
    static let shared = DictionaryStore()
    private var cached = PersonalDictionary()
    private var mtime: Date?

    var current: PersonalDictionary {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.dictionary.path)
        let m = attrs?[.modificationDate] as? Date
        if m == nil || m != mtime {
            cached = PersonalDictionary.load()
            mtime = (try? FileManager.default.attributesOfItem(atPath: Paths.dictionary.path))?[.modificationDate] as? Date
        }
        return cached
    }
}
