import AppKit
import SwiftUI

// MARK: - Cronologia (da ~/.voce/log.jsonl), raggruppata per giorno

struct HistoryPage: View {
    @ObservedObject private var controller = Controller.shared
    @ObservedObject private var nav = Navigation.shared
    @State private var search = ""

    var body: some View {
        let entries = controller.history.reversed().filter {
            search.isEmpty || $0.final.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search)
        }
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }
        Group {
            if entries.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Ancora nessuna dettatura", systemImage: "clock",
                                           description: Text("Tieni premuto il tasto di dettatura in qualsiasi app e parla."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                List {
                    ForEach(days.keys.sorted(by: >), id: \.self) { day in
                        Section(Self.title(day)) {
                            ForEach(days[day] ?? []) { entry in
                                HistoryRow(entry: entry) {
                                    nav.correctionSource = entry
                                    nav.dictionaryTab = .corrections
                                    nav.page = .dictionary
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Cerca nelle dettature")
    }

    private static func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Oggi" }
        if cal.isDateInYesterday(day) { return "Ieri" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "it_IT")))
    }
}

private struct HistoryRow: View {
    let entry: History.Entry
    let onCorrect: () -> Void
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        let app = AppInfo.lookup(entry.app)
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app").resizable() }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.final).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(meta(app.name)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { copy(entry.final); copied = true } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copia")
                Button(action: onCorrect) { Image(systemName: "character.book.closed") }
                    .help("Correggi una parola: crea una voce nel dizionario")
            }
            .buttonStyle(.borderless)
            .opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0; if !$0 { copied = false } }
        .contextMenu {
            Button("Copia testo") { copy(entry.final) }
            Button("Copia trascrizione grezza") { copy(entry.raw) }
            Button("Correggi una parola…", action: onCorrect)
        }
    }

    /// "Slack · 10:42 · Comando · AI · 0,4 s"
    private func meta(_ appName: String) -> String {
        var parts = [appName, entry.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""]
        if entry.mode == "command" { parts.append("Comando") } else if entry.llm { parts.append("Riscritto con AI") }
        parts.append(secondsText(entry.ms))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
