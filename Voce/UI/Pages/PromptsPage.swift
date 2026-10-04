import SwiftUI

// MARK: - Prompt: ogni istruzione che Voce dà a un modello, da leggere e personalizzare

struct PromptsPage: View {
    @ObservedObject private var nav = Navigation.shared
    @State private var revision = 0   // cambia quando un prompt viene salvato: aggiorna i segni «personalizzato»

    var body: some View {
        let selection = Binding<PromptID?>(get: { nav.promptID ?? .cleanup }, set: { if let id = $0 { nav.promptID = id } })
        HStack(spacing: 0) {
            List(selection: selection) {
                ForEach(PromptID.Group.allCases, id: \.self) { group in
                    Section(group == .dictation ? L("Dettatura") : L("Riunioni")) {
                        ForEach(PromptID.allCases.filter { $0.group == group }) { id in
                            HStack(spacing: 8) {
                                Image(systemName: id.symbol).frame(width: 18).foregroundStyle(.secondary)
                                Text(id.title).lineLimit(1)
                                Spacer(minLength: 4)
                                if PromptStore.shared.isCustom(id) {
                                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).help(L("Personalizzato"))
                                }
                            }
                            .tag(id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 230)
            .id(revision)
            Divider()
            PromptEditor(id: nav.promptID ?? .cleanup).id(nav.promptID ?? .cleanup)
        }
        .onReceive(NotificationCenter.default.publisher(for: PromptStore.didChange)) { _ in revision += 1 }
    }
}

private struct PromptEditor: View {
    let id: PromptID
    @State private var draft = ""
    @State private var saved = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var store: PromptStore { .shared }
    private var dirty: Bool { draft != saved }
    private var isDefault: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) == id.defaultText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: id.symbol, color: id.group == .dictation ? .blue : .pink, size: 26)
                Text(id.title).font(.title3.weight(.semibold))
                Text(isDefault ? L("Predefinito") : L("Personalizzato"))
                    .font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(isDefault ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.2)))
                Spacer()
            }
            Text(id.purpose).font(.callout).foregroundStyle(.secondary)

            if !id.placeholders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(id.placeholders, id: \.key) { p in
                        HStack(spacing: 6) {
                            Button("{{\(p.key)}}") { draft += (draft.hasSuffix("\n") || draft.isEmpty ? "" : "\n") + "{{\(p.key)}}" }
                                .buttonStyle(ChipStyle(selected: false)).font(.system(.callout, design: .monospaced))
                                .help(L("Aggiungi in fondo al prompt"))
                            Text(p.meaning).font(.caption).foregroundStyle(.secondary)
                            if !draft.contains("{{\(p.key)}}") {
                                Label(L("non c'è: il dato viene aggiunto in fondo"), systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dirty ? Color.accentColor.opacity(0.6) : .clear))

            if id == .meetingNames, !draft.localizedCaseInsensitiveContains("json") {
                Label(L("Il prompt non chiede più una risposta in JSON: «Suggerisci nomi» potrebbe non trovare nulla."),
                      systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if let testResult {
                Label {
                    Text(testResult.text).font(.caption).textSelection(.enabled).lineLimit(6)
                } icon: {
                    Image(systemName: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(testResult.ok ? .green : .red)
                }
            }

            HStack {
                Button(L("Ripristina il predefinito")) { draft = id.defaultText }
                    .disabled(isDefault)
                if canTest {
                    Button(testing ? L("Provo…") : L("Prova")) { test() }
                        .disabled(testing || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(L("Prova il testo che stai scrivendo su una frase d'esempio, senza salvarlo"))
                }
                Spacer()
                if dirty {
                    Text(L("Modifiche non salvate")).font(.caption).foregroundStyle(.secondary)
                    Button(L("Annulla")) { draft = saved }
                }
                Button(L("Salva")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            saved = store.text(id)
            draft = saved
        }
    }

    private func save() {
        store.set(id, draft)
        saved = store.text(id)
        draft = saved
    }

    // MARK: Prova

    private var canTest: Bool { id.group == .dictation }

    private func test() {
        testing = true
        testResult = nil
        let draft = self.draft, id = self.id, store = self.store
        let command = id == .command
        var config = Prefs.llm(command: command)
        config.timeout = 30   // la prima richiesta a un servizio sul Mac carica il modello
        let system: String
        let user: String
        switch id {
        case .command:
            system = draft
            user = "ISTRUZIONE: \(AIExample.instruction)\n\nTESTO:\n\(AIExample.selection)"
        case .cleanup:
            system = PromptStore.render(draft, placeholders: id.placeholders,
                                        values: ["stile": store.text(.styleChat), "vocabolario": DictionaryStore.shared.current.terms.joined(separator: ", ")])
            user = "TRASCRITTO: \(AIExample.spoken)"
        default:   // uno stile: dentro il prompt di riscrittura in uso
            system = store.render(.cleanup, ["stile": draft, "vocabolario": DictionaryStore.shared.current.terms.joined(separator: ", ")])
            user = "TRASCRITTO: \(AIExample.spoken)"
        }
        Task {
            defer { testing = false }
            do {
                let out = try await LLMClient.complete(system: system, user: user, config: config, maxTokens: 400)
                testResult = (true, L("«%@» → «%@»", command ? AIExample.selection : AIExample.spoken, out.replacingOccurrences(of: "\n", with: " ")))
            } catch {
                testResult = (false, LLMClient.friendly(error))
            }
        }
    }
}
