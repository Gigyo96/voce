import SwiftUI

// MARK: - Scheda Riepilogo

struct SummaryTab: View {
    let id: String
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var assistant = MeetingAssistant.shared
    @State private var notes = ""
    @State private var showNotes = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        if let meeting = store.meeting(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AINeededBanner()
                    if let failure = assistant.failures[id] {
                        Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: failure) { EmptyView() }
                    }
                    notesEditor
                    switch assistant.jobs[id] {
                    case .notes(let done, let total):
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(done), total: Double(max(total, 1)))
                            Text(L("Leggo la riunione… %ld di %ld", done + 1, total)).font(.caption).foregroundStyle(.secondary)
                        }
                    case .summary:
                        MarkdownText(text: assistant.partial[id] ?? "")
                        ProgressView().controlSize(.small)
                    default:
                        if let summary = meeting.summary {
                            HStack {
                                Button { copy(summary) } label: { Label(L("Copia"), systemImage: "doc.on.doc") }
                                Button { assistant.summarize(id) } label: { Label(L("Rigenera"), systemImage: "arrow.clockwise") }
                                Spacer()
                                Button { Navigation.shared.open(.meetingSummary) } label: { Label(L("Personalizza il prompt"), systemImage: "text.quote") }
                            }
                            .buttonStyle(.borderless).font(.callout)
                            MarkdownText(text: summary)
                        } else {
                            ContentUnavailableView {
                                Label(L("Nessun riepilogo"), systemImage: "text.document")
                            } description: {
                                Text(L("L'AI legge la trascrizione e scrive sintesi, decisioni e cose da fare."))
                            } actions: {
                                Button(L("Genera il riepilogo")) { assistant.summarize(id) }.buttonStyle(.borderedProminent)
                                Button(L("Personalizza il prompt")) { Navigation.shared.open(.meetingSummary) }.buttonStyle(.link)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

extension SummaryTab {
    /// Gli appunti dell'utente: contesto per il riepilogo e le domande, modificabili anche dopo.
    fileprivate var notesEditor: some View {
        DisclosureGroup(isExpanded: $showNotes) {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $notes).font(.body).scrollContentBackground(.hidden).focused($notesFocused)
                    .padding(6).frame(minHeight: 80)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                    .onChange(of: notesFocused) { _, focused in if !focused { commitNotes() } }
                Text(L("Il modello li legge insieme alla trascrizione. Dopo averli cambiati, rigenera il riepilogo."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label(L("Appunti"), systemImage: "square.and.pencil").font(.subheadline.weight(.medium))
        }
        .onAppear {
            notes = store.meeting(id)?.notes ?? ""
            showNotes = !notes.isEmpty
        }
        .onDisappear { commitNotes() }
    }

    private func commitNotes() {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != (store.meeting(id)?.notes ?? "") else { return }
        store.update(id) { $0.notes = clean.isEmpty ? nil : clean }
    }
}

// MARK: - Scheda Chiedi: la chat con la riunione

struct ChatTab: View {
    let id: String
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var assistant = MeetingAssistant.shared
    @State private var draft = ""

    private var suggestions: [String] {
        [L("Fammi un riepilogo della riunione"), L("Quali decisioni sono state prese?"),
         L("Elenca le cose da fare e chi se ne occupa"), L("Scrivi un'email di follow-up per i partecipanti"),
         L("Quali questioni sono rimaste aperte?")]
    }

    var body: some View {
        if let meeting = store.meeting(id) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            AINeededBanner()
                            if meeting.chat.isEmpty, assistant.jobs[id] == nil { intro }
                            ForEach(meeting.chat) { MessageView(message: $0) }
                            if assistant.jobs[id] == .answer || assistant.partial[id] != nil {
                                MessageView(message: .init(role: .assistant, text: assistant.partial[id] ?? ""), pending: true)
                            } else if case .notes(let done, let total) = assistant.jobs[id] {
                                Label(L("Leggo la riunione… %ld di %ld", done + 1, total), systemImage: "text.magnifyingglass")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let failure = assistant.failures[id] {
                                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: failure) {
                                    if meeting.chat.last?.role == .user { Button(L("Riprova")) { assistant.retry(id) } }
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(16)
                    }
                    .onChange(of: meeting.chat.count) { _, _ in proxy.scrollTo("bottom") }
                    .onChange(of: assistant.partial[id]) { _, _ in proxy.scrollTo("bottom") }
                }
                Divider()
                composer(meeting)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Chiedi qualsiasi cosa su questa riunione"), systemImage: "bubble.left.and.text.bubble.right").font(.headline)
            Text(L("Voce legge la trascrizione e risponde: recap, decisioni, chi ha detto cosa, bozze di email o verbali. Il testo va al servizio AI scelto in Funzioni AI; l'audio mai."))
                .font(.callout).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { assistant.ask(id, s) }.buttonStyle(ChipStyle(selected: false))
                }
            }
        }
    }

    private func composer(_ meeting: Meeting) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L("Scrivi una domanda…"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                .onSubmit(send)
            if assistant.isBusy(id) {
                Button { assistant.stop(id) } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).help(L("Interrompi"))
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(L("Invia"))
            }
            if !meeting.chat.isEmpty, !assistant.isBusy(id) {
                Button { assistant.clearChat(id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(L("Cancella la conversazione"))
            }
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        draft = ""
        assistant.ask(id, text)
    }
}

private struct MessageView: View {
    let message: Meeting.ChatMessage
    var pending = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty { ProgressView().controlSize(.small) } else { MarkdownText(text: message.text) }
                if !pending {
                    Button { copy(message.text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Copia"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
