import Foundation

/// Dove Voce tiene i suoi file. Tutto resta sul Mac.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dir = home.appending(path: ".voce")                  // dati dell'app
    static let history = dir.appending(path: "log.jsonl")            // cronologia delle dettature
    static let dictionary = dir.appending(path: "dictionary.json")   // dizionario personale
    static let dataset = home.appending(path: "voce-dataset")        // registrazioni salvate (facoltative, §10.1)
}
