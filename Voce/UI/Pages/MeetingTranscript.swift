import SwiftUI

// MARK: - Scheda Trascrizione: partecipanti da nominare, interventi, riascolto

struct TranscriptTab: View {
    let id: String
    let player: MeetingPlayer   // non osservato qui: lo osservano solo le righe visibili
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var assistant = MeetingAssistant.shared
    @State private var search = ""

    var body: some View {
        if let meeting = store.meeting(id) {
            let lines = search.isEmpty ? meeting.utterances : meeting.utterances.filter {
                $0.text.localizedCaseInsensitiveContains(search) || meeting.name(of: $0.speaker).localizedCaseInsensitiveContains(search)
            }
            List {
                Section {
                    TalkTimeBar(meeting: meeting)
                    ForEach(meeting.speakers.sorted { meeting.talkTime(of: $0.id) > meeting.talkTime(of: $1.id) }) { speaker in
                        SpeakerRow(meetingID: id, speakerID: speaker.id, player: player)
                    }
                    if let failure = assistant.failures[id] {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    HStack {
                        Text(L("Partecipanti"))
                        Spacer()
                        if assistant.jobs[id] == .names {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button { assistant.suggestNames(id) } label: { Label(L("Suggerisci nomi"), systemImage: "wand.and.stars") }
                                .buttonStyle(.link).font(.caption).disabled(assistant.isBusy(id))
                                .help(L("Cerca nella conversazione i nomi detti ad alta voce, per esempio «grazie, Marco»"))
                        }
                    }
                } footer: {
                    Text(L("Scrivi il nome di ognuno: compare ovunque, anche nelle risposte. Se una persona è divisa in due, uniscile dal menu."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(L("Interventi")) {
                    ForEach(lines) { utterance in
                        UtteranceRow(meetingID: id, utteranceID: utterance.id, player: player)
                    }
                }
            }
            .listStyle(.inset)
            .searchable(text: $search, placement: .toolbar, prompt: L("Cerca nella trascrizione"))
        }
    }
}

private struct SpeakerRow: View {
    let meetingID: String
    let speakerID: String
    let player: MeetingPlayer
    @ObservedObject private var store = MeetingStore.shared
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            let total = max(meeting.utterances.reduce(0) { $0 + ($1.end - $1.start) }, 1)
            HStack(spacing: 10) {
                Circle().fill(SpeakerStyle.color(speakerID, in: meeting)).frame(width: 10, height: 10)
                TextField(Meeting.defaultName(speakerID), text: $name)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                Text("\(Int((meeting.talkTime(of: speakerID) / total * 100).rounded()))%")
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    .help(L("Quota di parlato"))
                Button { playSample(meeting) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless).help(L("Ascolta un campione di questa voce"))
                Menu {
                    ForEach(meeting.speakers.filter { $0.id != speakerID }) { other in
                        Button(L("Unisci a %@", meeting.name(of: other.id))) {
                            store.update(meetingID) { $0.merge(speakerID, into: other.id); $0.digest = nil }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(meeting.speakers.count < 2)
                .help(L("Se è la stessa persona di un altro parlante"))
            }
            .onAppear { name = meeting.speakers.first { $0.id == speakerID }?.name ?? "" }
            .onChange(of: meeting.speakers.first { $0.id == speakerID }?.name) { _, new in if !focused { name = new ?? "" } }
        }
    }

    private func commit() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != (store.meeting(meetingID)?.speakers.first { $0.id == speakerID }?.name ?? "") else { return }
        store.update(meetingID) { m in
            guard let i = m.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            m.speakers[i].name = clean.isEmpty ? nil : clean
            m.digest = nil   // gli appunti per blocchi portano i vecchi nomi
        }
    }

    /// Il suo intervento più lungo, al massimo 8 secondi.
    private func playSample(_ meeting: Meeting) {
        guard let u = meeting.utterances.filter({ $0.speaker == speakerID }).max(by: { $0.end - $0.start < $1.end - $1.start }) else { return }
        player.play(from: u.start, until: min(u.end, u.start + 8))
    }
}

private struct UtteranceRow: View {
    let meetingID: String
    let utteranceID: Int
    @ObservedObject var player: MeetingPlayer
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        if let meeting = store.meeting(meetingID), let u = meeting.utterances.first(where: { $0.id == utteranceID }) {
            let active = player.isPlaying && player.time >= u.start && player.time < u.end + 0.3
            HStack(alignment: .top, spacing: 10) {
                Button { player.play(from: u.start) } label: {
                    Text(Meeting.clock(u.start)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).frame(width: 46, alignment: .leading).padding(.top, 2)
                .help(L("Ascolta da qui"))
                VStack(alignment: .leading, spacing: 2) {
                    Menu {
                        ForEach(meeting.speakers) { s in
                            Button(meeting.name(of: s.id)) { reassign(to: s.id) }
                        }
                        Divider()
                        Button(L("Nuovo parlante")) { reassign(to: nil) }
                    } label: {
                        Text(meeting.name(of: u.speaker)).font(.caption.bold()).foregroundStyle(SpeakerStyle.color(u.speaker, in: meeting))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("Chi ha detto questa frase? Cambia il parlante"))
                    Text(u.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .listRowBackground(active ? Color.accentColor.opacity(0.12) : Color.clear)
        }
    }

    /// Sposta questo intervento su un altro parlante (`nil` = uno nuovo).
    private func reassign(to speaker: String?) {
        store.update(meetingID) { m in
            guard let i = m.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
            m.utterances[i].speaker = speaker ?? m.addSpeaker()
            m.pruneSpeakers()
            m.digest = nil
        }
    }
}

/// Quanto ha parlato ciascuno, in una barra: si vede subito se la riunione è stata un monologo.
private struct TalkTimeBar: View {
    let meeting: Meeting

    var body: some View {
        let total = max(meeting.speakers.reduce(0) { $0 + meeting.talkTime(of: $1.id) }, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(meeting.speakers.sorted { meeting.talkTime(of: $0.id) > meeting.talkTime(of: $1.id) }) { s in
                    SpeakerStyle.color(s.id, in: meeting)
                        .frame(width: max(2, geo.size.width * meeting.talkTime(of: s.id) / total))
                        .help("\(meeting.name(of: s.id)) · \(Int((meeting.talkTime(of: s.id) / total * 100).rounded()))%")
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .listRowSeparator(.hidden)
    }
}
