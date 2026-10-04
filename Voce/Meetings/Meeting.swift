import Foundation

// MARK: - Modello di una riunione: audio, parlanti, trascrizione, riepilogo e chat

/// Una riunione registrata o importata. Vive in `~/.voce/meetings/<id>/meeting.json`, accanto al suo audio.
struct Meeting: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case recorded, imported }
    enum State: String, Codable, Sendable { case recording, processing, ready, failed }

    /// Un file audio da elaborare. `offset` = secondi tra l'inizio della riunione e il primo campione del file
    /// (microfono e audio del Mac partono con qualche decina di millisecondi di differenza).
    struct Track: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case mic       // la tua voce: un solo parlante, «Io»
            case system    // gli altri partecipanti, dall'audio del Mac: più parlanti da separare
            case mixed     // un file importato: tutti da separare
        }
        var kind: Kind
        var file: String
        var offset: Double = 0
    }

    struct Speaker: Codable, Identifiable, Equatable, Sendable {
        var id: String          // "me", "s1", "s2"…
        var name: String?       // nome scelto dall'utente; `nil` = etichetta predefinita
    }

    struct Utterance: Codable, Identifiable, Equatable, Sendable {
        var id: Int
        var speaker: String     // `Speaker.id`
        var start: Double
        var end: Double
        var text: String
    }

    struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case user, assistant }
        var id = UUID()
        var role: Role
        var text: String
        var date = Date()
    }

    var id: String
    var title: String
    var createdAt: Date
    var source: Source
    var state: State
    var error: String?
    var duration: TimeInterval = 0
    var tracks: [Track] = []
    var audio: String?                  // file da riascoltare (mix compresso)
    var speakers: [Speaker] = []
    var utterances: [Utterance] = []
    var notes: String?                  // appunti dell'utente: contesto per il riepilogo e per le domande
    var titleEdited = false             // `false`: il titolo può essere sostituito da quello proposto dal riepilogo
    var summary: String?
    var digest: [String]?               // note per blocchi: contesto compatto per le riunioni lunghe
    var chat: [ChatMessage] = []

    static let meID = "me"

    var folder: URL { Paths.meetings.appending(path: id) }
    /// Un file della riunione; un percorso assoluto (la riga di comando `Voce meeting`) resta com'è.
    func url(_ file: String) -> URL { file.hasPrefix("/") ? URL(fileURLWithPath: file) : folder.appending(path: file) }
    var audioURL: URL? { audio.map(url) }

    // MARK: Parlanti

    /// Nome da mostrare: quello scelto dall'utente, altrimenti «Io» / «Parlante 2».
    func name(of speakerID: String) -> String {
        if let name = speakers.first(where: { $0.id == speakerID })?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return Self.defaultName(speakerID)
    }

    static func defaultName(_ speakerID: String) -> String {
        if speakerID == meID { return L("Io") }
        return L("Parlante %ld", Int(speakerID.drop { !$0.isNumber }) ?? 0)
    }

    /// Un nuovo parlante, per assegnare un intervento a qualcuno che la separazione automatica non ha distinto.
    mutating func addSpeaker() -> String {
        let next = (speakers.compactMap { Int($0.id.drop { !$0.isNumber }) }.max() ?? 0) + 1
        speakers.append(Speaker(id: "s\(next)"))
        return "s\(next)"
    }

    /// Toglie i parlanti senza più interventi (dopo uno spostamento o un'unione).
    mutating func pruneSpeakers() {
        let used = Set(utterances.map(\.speaker))
        speakers.removeAll { !used.contains($0.id) }
    }

    /// Sposta tutti gli interventi di `from` su `into` (stessa persona separata in due).
    mutating func merge(_ from: String, into: String) {
        guard from != into else { return }
        for i in utterances.indices where utterances[i].speaker == from { utterances[i].speaker = into }
        pruneSpeakers()
    }

    /// Chi ha parlato di più, in secondi: l'ordine con cui si mostrano i parlanti.
    func talkTime(of speakerID: String) -> Double {
        utterances.filter { $0.speaker == speakerID }.reduce(0) { $0 + ($1.end - $1.start) }
    }

    // MARK: Testo

    /// Due righe per l'elenco: l'inizio del riepilogo se c'è, altrimenti le prime parole della trascrizione.
    var preview: String {
        let fromSummary = summary?.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•#").union(.whitespaces)) }
            .first { !$0.isEmpty && !$0.hasPrefix("[") && $0.count > 20 }
        return (fromSummary ?? utterances.first?.text ?? "").replacingOccurrences(of: "**", with: "")
    }

    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// «[00:12] Marco: testo», un intervento per riga: è anche quello che si dà al modello.
    func transcriptText(timestamps: Bool = true) -> String {
        utterances.map { line($0, timestamps: timestamps) }.joined(separator: "\n")
    }

    func line(_ u: Utterance, timestamps: Bool = true, speaker: ((String) -> String)? = nil) -> String {
        (timestamps ? "[\(Self.clock(u.start))] " : "") + "\((speaker ?? name(of:))(u.speaker)): \(u.text)"
    }

    /// Documento Markdown da salvare o condividere.
    func markdown() -> String {
        var out = "# \(title)\n\n"
        out += createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Loc.locale))
        out += " · \(Self.clock(duration))\n\n"
        let names = speakers.sorted { talkTime(of: $0.id) > talkTime(of: $1.id) }.map { name(of: $0.id) }
        if !names.isEmpty { out += "**\(L("Partecipanti")):** \(names.joined(separator: ", "))\n\n" }
        if let summary, !summary.isEmpty { out += "\(summary)\n\n" }
        out += "## \(L("Trascrizione"))\n\n"
        out += utterances.map { "**\(name(of: $0.speaker))** (\(Self.clock($0.start))): \($0.text)" }.joined(separator: "\n\n")
        return out + "\n"
    }

    static func newID(_ date: Date = Date()) -> String { History.timestamp(date) }

    static func defaultTitle(_ date: Date = Date()) -> String {
        L("Riunione del %@", date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Loc.locale)))
    }
}
