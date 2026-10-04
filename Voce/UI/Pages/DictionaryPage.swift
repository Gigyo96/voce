import AppKit
import SwiftUI

// MARK: - Modello: modifica ~/.voce/dictionary.json (DictionaryStore lo ricarica alla prossima dettatura)

@MainActor final class DictionaryModel: ObservableObject {
    static let shared = DictionaryModel()

    @Published private(set) var dictionary = PersonalDictionary()
    /// File presente ma non leggibile: si mostra l'errore e non si salva nulla, per non perdere il contenuto.
    @Published private(set) var loadError: String?
    @Published var saveError: String?

    var terms: [String] { dictionary.terms.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    var corrections: [(spoken: String, written: String)] {
        dictionary.replace.map { ($0.key, $0.value) }.sorted { $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending }
    }

    func reload() {
        do {
            dictionary = try PersonalDictionary.read()
            loadError = nil
        } catch {
            loadError = (error as? DecodingError).map { _ in "dictionary.json non è un JSON valido." } ?? error.localizedDescription
        }
    }

    func contains(term: String) -> Bool {
        dictionary.terms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

    /// `false` se vuoto o già presente.
    @discardableResult func addTerm(_ raw: String) -> Bool {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !contains(term: term) else { return false }
        var d = dictionary
        d.terms.append(term)
        return commit(d)
    }

    func removeTerm(_ term: String) {
        var d = dictionary
        d.terms.removeAll { $0 == term }
        commit(d)
    }

    /// Aggiunge o sostituisce una correzione "trascritto come → scrivi". `alsoTerm`: la forma scritta entra anche nei
    /// termini, così il boosting CTC la cerca nell'audio.
    @discardableResult func setCorrection(spoken raw: String, written rawWritten: String, replacing old: String? = nil,
                                          alsoTerm: Bool) -> Bool {
        let spoken = PersonalDictionary.key(raw), written = rawWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !written.isEmpty, spoken != PersonalDictionary.key(written) else { return false }
        var d = dictionary
        if let old { d.replace.removeValue(forKey: old) }
        d.replace[spoken] = written
        if alsoTerm, !d.terms.contains(where: { $0.caseInsensitiveCompare(written) == .orderedSame }) { d.terms.append(written) }
        return commit(d)
    }

    func removeCorrection(_ spoken: String) {
        var d = dictionary
        d.replace.removeValue(forKey: spoken)
        commit(d)
    }

    @discardableResult private func commit(_ d: PersonalDictionary) -> Bool {
        guard loadError == nil else { return false }
        do {
            try d.save()
            dictionary = d
            saveError = nil
            return true
        } catch {
            saveError = "Salvataggio non riuscito: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Vista

enum DictionaryTab: String, CaseIterable { case terms, corrections }

struct DictionaryPage: View {
    @ObservedObject private var model = DictionaryModel.shared
    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var controller = Controller.shared
    @State private var search = ""
    @State private var newTerm = ""
    @State private var spoken = ""
    @State private var written = ""
    @State private var alsoTerm = true
    @State private var editing: String?
    @State private var trial = ""
    @FocusState private var focus: Field?

    private enum Field { case term, spoken, written, trial }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.loadError {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: "\(error) Correggilo a mano: finché non è valido l'editor resta in sola lettura.") {
                        Button("Apri file") { NSWorkspace.shared.open(Paths.dictionary) }
                        Button("Ricarica") { model.reload() }
                    }
                }
                if let error = model.saveError {
                    Banner(symbol: "xmark.octagon.fill", tint: .red, text: error) { EmptyView() }
                }
                Text("Come Voce deve scrivere i nomi che usi: librerie, comandi, persone, prodotti.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Group {
                switch nav.dictionaryTab {
                case .terms: termsPane
                case .corrections: correctionsPane
                }
            }
            .disabled(model.loadError != nil)

            Divider()
            trialBar
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vista", selection: $nav.dictionaryTab) {
                    Text("Termini").tag(DictionaryTab.terms)
                    Text("Correzioni").tag(DictionaryTab.corrections)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Cerca")
        .onAppear { model.reload() }
    }

    // MARK: Termini

    private var termsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Nuovo termine, es. Supabase, useEffect, Claude Code", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .term)
                    .onSubmit(addTerm)
                Button("Aggiungi", action: addTerm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            if model.contains(term: newTerm.trimmingCharacters(in: .whitespaces)) {
                Text("È già nel dizionario.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }

            let terms = model.terms.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            if terms.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Nessun termine", systemImage: "character.book.closed",
                                           description: Text("Aggiungi le parole che Voce sbaglia più spesso: le scriverà sempre così."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List {
                    ForEach(terms, id: \.self) { term in
                        TermRow(term: term) { model.removeTerm(term) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func addTerm() {
        if model.addTerm(newTerm) { newTerm = "" }
        focus = .term
    }

    // MARK: Correzioni

    private var correctionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let source = nav.correctionSource ?? controller.history.last {
                QuickFix(entry: source) { phrase in
                    spoken = phrase
                    editing = nil
                    focus = .written
                }
                .padding(.horizontal, 20)
            }
            HStack(spacing: 8) {
                TextField("Trascritto come", text: $spoken, prompt: Text("Trascritto come… es. cube cuttle"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .spoken)
                    .onSubmit { focus = .written }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Scrivi", text: $written, prompt: Text("Scrivi… es. kubectl"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .written)
                    .onSubmit(addCorrection)
                Button(editing == nil ? "Aggiungi" : "Salva", action: addCorrection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(spoken.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
                if editing != nil {
                    Button("Annulla") { editing = nil; spoken = ""; written = "" }
                }
            }
            .padding(.horizontal, 20)
            Toggle("Aggiungi la forma scritta anche ai termini (aiuta il riconoscimento)", isOn: $alsoTerm)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 20)

            let rows = model.corrections.filter {
                search.isEmpty || $0.spoken.localizedCaseInsensitiveContains(search) || $0.written.localizedCaseInsensitiveContains(search)
            }
            if rows.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Nessuna correzione", systemImage: "arrow.triangle.swap",
                                           description: Text("Quando Voce trascrive male una parola, cliccala qui sopra e scrivi la forma giusta."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List {
                    ForEach(rows, id: \.spoken) { row in
                        CorrectionRow(spoken: row.spoken, written: row.written, selected: editing == row.spoken) {
                            editing = row.spoken
                            spoken = row.spoken
                            written = row.written
                            focus = .written
                        } onDelete: {
                            model.removeCorrection(row.spoken)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func addCorrection() {
        guard model.setCorrection(spoken: spoken, written: written, replacing: editing, alsoTerm: alsoTerm) else { return }
        spoken = ""
        written = ""
        editing = nil
        focus = .spoken
    }

    // MARK: Prova

    private var trialBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.badge.checkmark").foregroundStyle(.secondary)
            TextField("Prova: scrivi una frase come la trascriverebbe Voce", text: $trial)
                .textFieldStyle(.plain)
                .focused($focus, equals: .trial)
            if !trial.isEmpty {
                let out = Rules.tidy(model.dictionary.apply(trial))
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text(out)
                    .foregroundStyle(out == Rules.tidy(trial) ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.open(Paths.dictionary)
            } label: {
                Label("dictionary.json", systemImage: "curlybraces")
            }
            .buttonStyle(.link)
            .help("Apri il file JSON: Voce lo ricarica a ogni modifica")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Righe

private struct TermRow: View {
    let term: String
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term).font(.system(.body, design: .monospaced))
                let forms = PersonalDictionary.spokenForms(of: term).dropFirst()
                if !forms.isEmpty {
                    Text("riconosce anche: " + forms.map { "«\($0.lowercased())»" }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            DeleteButton(visible: hover, action: onDelete)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copia") { copy(term) }
            Button("Elimina", role: .destructive, action: onDelete)
        }
    }
}

private struct CorrectionRow: View {
    let spoken: String
    let written: String
    let selected: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack {
            Text(spoken).foregroundStyle(.secondary).strikethrough(true, color: .secondary.opacity(0.5))
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(written).font(.system(.body, design: .monospaced))
            Spacer()
            if hover || selected {
                Button("Modifica", action: onEdit).buttonStyle(.link).font(.caption)
            }
            DeleteButton(visible: hover, action: onDelete)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu {
            Button("Modifica", action: onEdit)
            Button("Elimina", role: .destructive, action: onDelete)
        }
    }
}

private struct DeleteButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(visible ? 1 : 0)
        .help("Elimina")
        .accessibilityLabel("Elimina")
    }
}

/// Ultima dettatura come parole cliccabili: si selezionano le parole sbagliate (contigue) per creare una correzione.
private struct QuickFix: View {
    let entry: History.Entry
    let onPick: (String) -> Void
    @State private var range: ClosedRange<Int>?

    private var words: [String] {
        (entry.boosted ?? entry.raw).split(whereSeparator: \.isWhitespace).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Correggi dall'ultima dettatura", systemImage: "wand.and.rays").font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.date.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Clicca la parola trascritta male (o la prima e l'ultima di più parole).")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                FlowLayout(spacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                        Button(word) { tap(i) }
                            .buttonStyle(ChipStyle(selected: range?.contains(i) == true))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 84)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .onChange(of: entry.id) { range = nil }
    }

    private func tap(_ i: Int) {
        if let r = range, r.count == 1, r.lowerBound != i {
            range = min(r.lowerBound, i)...max(r.lowerBound, i)
        } else {
            range = i...i
        }
        if let range { onPick(words[range].joined(separator: " ").lowercased()) }
    }
}
