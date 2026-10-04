import Foundation
import Testing
@testable import Voce

// Prompt personalizzabili: predefiniti, salvataggio, segnaposto che non si perdono.

@Suite struct PromptStoreTests {
    private func store() -> (PromptStore, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "voce-prompts-\(UUID().uuidString).json")
        return (PromptStore(url: url), url)
    }

    @Test func defaultsUntilTheUserChangesThem() {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(s.text(.meetingSummary) == PromptID.meetingSummary.defaultText)
        #expect(!s.isCustom(.meetingSummary))
        s.set(.meetingSummary, "Riassumi in tre punti, in inglese.")
        #expect(s.text(.meetingSummary) == "Riassumi in tre punti, in inglese.")
        #expect(s.isCustom(.meetingSummary))
        // Si rilegge dal file.
        #expect(PromptStore(url: url).text(.meetingSummary) == "Riassumi in tre punti, in inglese.")
    }

    @Test func emptyOrDefaultTextMeansDefault() {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        s.set(.command, "Altro")
        s.set(.command, "   ")
        #expect(!s.isCustom(.command))
        s.set(.command, "Altro")
        s.set(.command, PromptID.command.defaultText + "\n")
        #expect(!s.isCustom(.command))
    }

    @Test func placeholdersAreFilled() {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let out = Prompts.cleanup(profile: .email, terms: ["Supabase", "kubectl"], store: s)
        #expect(out.contains("PROFILO: " + PromptID.styleEmail.defaultText))
        #expect(out.contains("VOCABOLARIO: Supabase, kubectl"))
        #expect(!out.contains("{{"))
    }

    @Test func removedPlaceholdersStillCarryTheirData() {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        s.set(.cleanup, "Correggi il testo. Tono: {{stile}}")
        s.set(.styleChat, "Scrivi come un pirata.")
        let out = Prompts.cleanup(profile: .chat, terms: ["Voce"], store: s)
        #expect(out.hasPrefix("Correggi il testo. Tono: Scrivi come un pirata."))
        #expect(out.hasSuffix("\n\nVOCABOLARIO: Voce"))
        // Senza termini non si aggiunge nulla.
        #expect(!Prompts.cleanup(profile: .chat, terms: [], store: s).contains("VOCABOLARIO"))
    }

    @Test func everyPromptHasTextAndItsPlaceholders() {
        for id in PromptID.allCases {
            #expect(!id.defaultText.isEmpty)
            #expect(!id.title.isEmpty && !id.purpose.isEmpty)
            for p in id.placeholders { #expect(id.defaultText.contains("{{\(p.key)}}"), "\(id) senza {{\(p.key)}}") }
        }
    }
}
