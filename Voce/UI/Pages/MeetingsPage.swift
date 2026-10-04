import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Riunioni: registra o importa, poi trascrizione con i parlanti, riepilogo e chat

struct MeetingsPage: View {
    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        if recorder.isRecording {
            RecordingView()
        } else if let id = nav.meetingID, store.meeting(id) != nil {
            MeetingDetailView(id: id)
        } else {
            MeetingList()
        }
    }
}

// MARK: - Elenco

private struct MeetingList: View {
    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @AppStorage(Prefs.meetingCaptureSystem) private var captureSystem
    @State private var importing = false
    @State private var dropping = false
    @State private var search = ""
    @State private var confirmDelete: Meeting?

    private var filtered: [Meeting] {
        guard !search.isEmpty else { return store.meetings }
        return store.meetings.filter { m in
            m.title.localizedCaseInsensitiveContains(search) || (m.summary ?? "").localizedCaseInsensitiveContains(search)
                || m.utterances.contains { $0.text.localizedCaseInsensitiveContains(search) }
                || m.speakers.contains { m.name(of: $0.id).localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        let days = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.createdAt) }
        VStack(spacing: 0) {
            startCard.padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            if store.meetings.isEmpty {
                ContentUnavailableView(L("Ancora nessuna riunione"), systemImage: "person.2.wave.2",
                                       description: Text(L("Le riunioni registrate o importate compaiono qui, con trascrizione, riepilogo e chat.")))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(days.keys.sorted(by: >), id: \.self) { day in
                        Section(Self.title(day)) {
                            ForEach(days[day] ?? []) { meeting in
                                MeetingRow(meeting: meeting) { confirmDelete = meeting }
                                    .onTapGesture { nav.meetingID = meeting.id }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: L("Cerca nelle riunioni"))
        .overlay { if dropping { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Self.urls(from: providers) { store.importAudio($0) }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importAudio(urls) }
        }
        .confirmationDialog(L("Eliminare la riunione?"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { meeting in
            Button(L("Sposta nel Cestino"), role: .destructive) { store.delete(meeting.id) }
        } message: { meeting in
            Text(L("«%@» e il suo audio vengono spostati nel Cestino.", meeting.title))
        }
    }

    /// Come si comincia: registrare (con o senza l'audio del Mac) o importare un file.
    private var startCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { recorder.start() } label: {
                    Label(L("Registra riunione"), systemImage: "record.circle").frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                Button { importing = true } label: {
                    Label(L("Importa audio…"), systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                Spacer()
                Toggle(isOn: $captureSystem) { Text(L("Registra anche l'audio del Mac")) }
                    .toggleStyle(.checkbox)
                    .help(L("Le voci degli altri in Meet, Zoom, Teams, YouTube… Senza, si registra solo il microfono."))
            }
            if let warning = recorder.warning {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: warning) {
                    Button(L("Impostazioni…")) { Permissions.open("Privacy_AudioCapture") }
                    Button { recorder.dismissWarning() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            } else {
                Text(L("Oppure trascina qui un file audio o video. Tutto viene trascritto sul tuo Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
            .background(Color.accentColor.opacity(0.08)).padding(8).allowsHitTesting(false)
            .overlay { Label(L("Rilascia il file per importarlo"), systemImage: "square.and.arrow.down").font(.title3) }
    }

    private static func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L("Oggi") }
        if cal.isDateInYesterday(day) { return L("Ieri") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Loc.locale))
    }

    private static func urls(from providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        nonisolated(unsafe) var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.sync { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let onDelete: () -> Void
    @ObservedObject private var store = MeetingStore.shared
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(meeting.state == .failed ? Color.orange : .secondary).lineLimit(1)
                if meeting.state == .ready, !meeting.preview.isEmpty {
                    Text(meeting.preview).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let p = store.progress[meeting.id], meeting.state == .processing {
                    ProgressView(value: p.fraction).controlSize(.small).frame(maxWidth: 220)
                }
            }
            Spacer(minLength: 8)
            if meeting.state == .ready { SpeakerDots(meeting: meeting) }
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(L("Elimina")).opacity(hover ? 1 : 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Apri")) { Navigation.shared.meetingID = meeting.id }
            if meeting.state == .failed, !meeting.tracks.isEmpty { Button(L("Riprova l'elaborazione")) { store.process(meeting.id) } }
            Button(L("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
            Divider()
            Button(L("Elimina…"), role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var icon: some View {
        switch meeting.state {
        case .ready: IconTile(symbol: meeting.source == .recorded ? "person.2.wave.2.fill" : "waveform", color: .pink)
        case .recording: IconTile(symbol: "record.circle", color: .red)
        case .processing: ProgressView().controlSize(.small)
        case .failed: IconTile(symbol: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    private var subtitle: String {
        switch meeting.state {
        case .recording: return L("In registrazione…")
        case .processing:
            switch store.progress[meeting.id]?.stage {
            case .separating: return L("Distinguo chi parla…")
            case .finishing: return L("Quasi fatto…")
            default: return store.progress[meeting.id] == nil ? L("In coda…") : L("Trascrivo…")
            }
        case .failed: return meeting.error ?? L("Non riuscita")
        case .ready:
            return [meeting.createdAt.formatted(date: .omitted, time: .shortened), Meeting.clock(meeting.duration)].joined(separator: " · ")
        }
    }
}

/// I partecipanti come cerchietti con l'iniziale, nel colore che hanno nella trascrizione.
private struct SpeakerDots: View {
    let meeting: Meeting

    var body: some View {
        let ids = meeting.speakers.sorted { meeting.talkTime(of: $0.id) > meeting.talkTime(of: $1.id) }.map(\.id)
        HStack(spacing: -6) {
            ForEach(ids.prefix(4), id: \.self) { id in
                Text(String(meeting.name(of: id).first(where: \.isLetter) ?? "?").uppercased())
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(SpeakerStyle.color(id, in: meeting)))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            if ids.count > 4 {
                Text("+\(ids.count - 4)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 10)
            }
        }
        .help(ids.map { meeting.name(of: $0) }.joined(separator: ", "))
    }
}

// MARK: - Registrazione in corso

/// La pagina durante la registrazione: tempo, le due sorgenti con la loro forma d'onda, titolo e appunti.
struct RecordingView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var pulse = false
    @State private var confirmDiscard = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10).opacity(pulse ? 0.25 : 1)
                            .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                        Text(L("In registrazione")).font(.callout.weight(.medium)).foregroundStyle(.red)
                    }
                    Text(Meeting.clock(Double(recorder.seconds)))
                        .font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit()
                }
                .frame(maxWidth: .infinity).padding(.top, 8)

                TextField(L("Titolo"), text: $recorder.title)
                    .textFieldStyle(.plain).font(.title3.weight(.semibold)).multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    SourceCard(title: L("Microfono"), device: recorder.micDevice, symbol: "mic.fill", mutedSymbol: "mic.slash.fill",
                               kind: .mic, available: true, muted: $recorder.micMuted)
                    SourceCard(title: L("Audio del Mac"), device: recorder.outputDevice, symbol: "speaker.wave.2.fill",
                               mutedSymbol: "speaker.slash.fill", kind: .system, available: recorder.systemAvailable,
                               muted: $recorder.systemMuted)
                }

                if let warning = recorder.warning {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: warning) {
                        Button(L("Impostazioni…")) { Permissions.open("Privacy_AudioCapture") }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(L("Appunti"), systemImage: "square.and.pencil").font(.subheadline.weight(.medium))
                    TextEditor(text: $recorder.notes)
                        .font(.body).scrollContentBackground(.hidden)
                        .padding(8).frame(minHeight: 110)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                    Text(L("Contesto per il riepilogo e le domande: obiettivo della riunione, nomi dei partecipanti, termini da conoscere. Non finiscono nella trascrizione."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button(role: .destructive) { confirmDiscard = true } label: { Label(L("Scarta"), systemImage: "trash") }
                        .controlSize(.large)
                    Spacer()
                    Button { Navigation.shared.meetingID = recorder.stop() } label: {
                        Label(L("Ferma e trascrivi"), systemImage: "stop.circle.fill").frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { pulse = true }
        .confirmationDialog(L("Scartare la registrazione?"), isPresented: $confirmDiscard) {
            Button(L("Scarta"), role: .destructive) { recorder.cancel() }
        } message: {
            Text(L("L'audio registrato finora viene eliminato."))
        }
    }
}

/// Una sorgente: nome, dispositivo, forma d'onda degli ultimi secondi e tasto per silenziarla.
private struct SourceCard: View {
    enum Kind { case mic, system }
    let title: String
    let device: String
    let symbol: String
    let mutedSymbol: String
    let kind: Kind
    let available: Bool
    @Binding var muted: Bool
    @ObservedObject private var levels = MeetingRecorder.shared.levels

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: available && !muted ? symbol : mutedSymbol)
                .font(.title3).foregroundStyle(available && !muted ? Color.primary : .secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            LevelBars(levels: kind == .mic ? levels.mic : levels.system, tint: muted || !available ? .gray : .green)
                .frame(height: 34)
            Button { muted.toggle() } label: { Text(muted ? L("Silenziato") : L("Silenzia")).frame(minWidth: 62) }
                .controlSize(.small).disabled(!available)
                .help(muted ? L("Riattiva: torna a registrare") : L("Silenzia: la traccia resta ma senza audio"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .opacity(available ? 1 : 0.6)
    }

    private var subtitle: String {
        if !available { return L("Non disponibile") }
        if muted { return L("Silenziato") }
        return device.isEmpty ? L("In ascolto") : device
    }
}

/// Barre che scorrono da destra a sinistra: il suono più recente è a destra.
private struct LevelBars: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let slot = size.width / CGFloat(levels.count)
            for (i, level) in levels.enumerated() {
                // Scala radice: il parlato normale (RMS ~0,05) riempie circa metà dell'altezza.
                let h = max(2, size.height * CGFloat(min(1, level.squareRoot() * 2.2)))
                let bar = CGRect(x: CGFloat(i) * slot + slot * 0.2, y: (size.height - h) / 2, width: slot * 0.6, height: h)
                context.fill(Path(roundedRect: bar, cornerRadius: slot * 0.3), with: .color(tint.opacity(0.35 + 0.65 * Double(i) / Double(levels.count))))
            }
        }
    }
}
