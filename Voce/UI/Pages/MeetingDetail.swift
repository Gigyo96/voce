import AppKit
import SwiftUI

// MARK: - Una riunione: trascrizione con i parlanti, riepilogo, chat

struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case transcript, summary, chat
        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcript: return L("Trascrizione")
            case .summary: return L("Riepilogo")
            case .chat: return L("Chiedi")
            }
        }
    }

    let id: String
    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var store = MeetingStore.shared
    @StateObject private var player = MeetingPlayer()
    @State private var tab: Tab = .transcript
    @State private var title = ""
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let meeting = store.meeting(id) {
            VStack(spacing: 0) {
                header(meeting).padding([.horizontal, .top], 16).padding(.bottom, 10)
                Divider()
                content(meeting)
            }
            .onAppear {
                title = meeting.title
                player.load(meeting.audioURL)
                AIStatus.shared.refresh(delay: .zero)
            }
            .onDisappear {
                commitTitle()
                player.stop()
            }
            .onChange(of: meeting.audioURL) { _, url in player.load(url) }
            .onChange(of: meeting.title) { _, new in if !titleFocused { title = new } }
            .confirmationDialog(L("Eliminare la riunione?"), isPresented: $confirmDelete) {
                Button(L("Sposta nel Cestino"), role: .destructive) {
                    nav.meetingID = nil
                    store.delete(id)
                }
            } message: {
                Text(L("«%@» e il suo audio vengono spostati nel Cestino.", meeting.title))
            }
        }
    }

    // MARK: Intestazione

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { nav.meetingID = nil } label: { Label(L("Riunioni"), systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                if meeting.state == .ready { actionsMenu(meeting) }
            }
            TextField(L("Titolo"), text: $title)
                .textFieldStyle(.plain).font(.title2.bold())
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            Text(meta(meeting)).font(.caption).foregroundStyle(.secondary)
            if meeting.state == .ready, meeting.audioURL != nil { PlayerBar(player: player) }
        }
    }

    private func meta(_ meeting: Meeting) -> String {
        let people = meeting.speakers.count
        return [meeting.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Loc.locale)),
                Meeting.clock(meeting.duration),
                meeting.state == .ready ? (people == 1 ? L("1 parlante") : L("%ld parlanti", people)) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func commitTitle() {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != store.meeting(id)?.title else { return }
        store.update(id) { $0.title = clean; $0.titleEdited = true }
    }

    private func actionsMenu(_ meeting: Meeting) -> some View {
        Menu {
            Button(L("Copia la trascrizione")) { copy(meeting.transcriptText()) }
            if let summary = meeting.summary { Button(L("Copia il riepilogo")) { copy(summary) } }
            Button(L("Salva come Markdown…")) { exportMarkdown(meeting) }
            Divider()
            Button(L("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
            if !meeting.tracks.isEmpty { Button(L("Rielabora")) { store.process(id) } }
            Divider()
            Button(L("Elimina…"), role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func exportMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? meeting.markdown().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Contenuto

    @ViewBuilder private func content(_ meeting: Meeting) -> some View {
        switch meeting.state {
        case .recording, .processing:
            ProcessingView(meeting: meeting)
        case .failed:
            ContentUnavailableView {
                Label(L("Non sono riuscito a elaborare la riunione"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(meeting.error ?? "")
            } actions: {
                if !meeting.tracks.isEmpty { Button(L("Riprova")) { store.process(id) }.buttonStyle(.borderedProminent) }
                Button(L("Elimina…"), role: .destructive) { confirmDelete = true }
            }
        case .ready:
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 8)
                switch tab {
                case .transcript: TranscriptTab(id: id, player: player)
                case .summary: SummaryTab(id: id)
                case .chat: ChatTab(id: id)
                }
            }
        }
    }
}

private struct ProcessingView: View {
    let meeting: Meeting
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        let p = store.progress[meeting.id]
        VStack(spacing: 14) {
            Spacer()
            if meeting.state == .recording {
                Label(L("Registrazione in corso…"), systemImage: "record.circle").foregroundStyle(.red)
            } else {
                ProgressView(value: p?.fraction ?? 0).frame(maxWidth: 280)
                Text(label(p?.stage)).foregroundStyle(.secondary)
                Text(L("Puoi chiudere questa pagina: l'elaborazione continua."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func label(_ stage: MeetingPipeline.Stage?) -> String {
        switch stage {
        case nil: return L("In coda…")
        case .transcribing: return L("Trascrivo l'audio…")
        case .separating: return L("Distinguo chi parla…")
        case .finishing: return L("Quasi fatto…")
        }
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14) }
                .buttonStyle(.borderless)
            Text(Meeting.clock(player.time)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                .controlSize(.small)
            Text(Meeting.clock(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Colore di un parlante: lo stesso nell'elenco dei partecipanti e accanto a ogni intervento.
enum SpeakerStyle {
    static let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint]

    static func color(_ speaker: String, in meeting: Meeting) -> Color {
        if speaker == Meeting.meID { return .blue }
        let others = meeting.speakers.map(\.id).filter { $0 != Meeting.meID }
        return palette[(others.firstIndex(of: speaker) ?? 0) % palette.count]
    }
}

/// Avviso quando manca il servizio AI: riepilogo e chat ne hanno bisogno, la trascrizione no.
struct AINeededBanner: View {
    @ObservedObject private var status = AIStatus.shared

    var body: some View {
        if case .failed(let why) = status.command {
            Banner(symbol: "sparkles", tint: .orange, text: L("Per riepilogo e domande serve un servizio AI. %@", why)) {
                Button(L("Configura")) { Navigation.shared.page = .ai }
            }
        }
    }
}
