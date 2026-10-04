import Foundation
import Testing
@testable import Voce

// Interfaccia in italiano e inglese: ogni testo passato a L() deve avere la traduzione nel String Catalog.

@Suite struct LocalizationTests {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Voce")
        .standardizedFileURL

    /// Le chiavi scritte nel codice come `L("…")`.
    private static func keysInSource() throws -> Set<String> {
        let re = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(m.range(at: 1), in: text)!])
                keys.insert(raw.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n"))
            }
        }
        return keys
    }

    @Test func everyTextHasAnEnglishTranslation() throws {
        let keys = try Self.keysInSource()
        #expect(keys.count > 200)
        let missing = keys.filter { Loc.english[$0] == nil }.sorted()
        #expect(missing.isEmpty, "Senza traduzione in Localizable.xcstrings: \(missing)")
    }

    @Test func placeholdersMatch() {
        func placeholders(_ s: String) -> [String] {
            s.matches(of: /%(?:ld|@|%)/).map { String($0.output) }.sorted()
        }
        for (key, value) in Loc.english {
            #expect(placeholders(key) == placeholders(value), "Segnaposto diversi: \(key)")
        }
    }

    @Test func noUnusedTranslations() throws {
        let unused = Set(Loc.english.keys).subtracting(try Self.keysInSource()).sorted()
        #expect(unused.isEmpty, "Traduzioni non più usate: \(unused)")
    }
}
