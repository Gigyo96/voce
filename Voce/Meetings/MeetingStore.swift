import AppKit
import Foundation

/// L'archivio delle riunioni (`~/.voce/meetings`) e la coda di elaborazione: una riunione alla volta, per non
/// contendere il Neural Engine alla dettatura.
@MainActor final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    struct Progress: Equatable {
        var stage: MeetingPipeline.Stage
        var fraction: Double
    }

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var progress: [String: Progress] = [:]

    private var queue: [String] = []
    private var worker: Task<Void, Never>?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    // MARK: Archivio

    /// Legge le cartelle. Una riunione rimasta «in registrazione» o «in elaborazione» è stata interrotta da una chiusura
    /// dell'app: si segna come fallita, con le tracce intatte per poterla rielaborare.
    func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for folder in folders {
            guard var m = (try? Data(contentsOf: folder.appending(path: "meeting.json"))).flatMap({ try? Self.decoder.decode(Meeting.self, from: $0) }) else { continue }
            let interrupted = (m.state == .recording && !MeetingRecorder.shared.isRecording) || (m.state == .processing && !queue.contains(m.id))
            if interrupted {
                m.error = m.state == .recording ? L("Registrazione interrotta.") : L("Elaborazione interrotta.")
                m.state = .failed
                persist(m)
            }
            loaded.append(m)
        }
        meetings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        persist(meeting)
    }

    /// Solo in memoria, senza scrivere sul disco: per `Voce snapshot`.
    func insertForPreview(_ meeting: Meeting) { meetings.insert(meeting, at: 0) }

    func update(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        persist(meetings[i])
    }

    func delete(_ id: String) {
        guard let m = meeting(id) else { return }
        queue.removeAll { $0 == id }
        meetings.removeAll { $0.id == id }
        // Nel Cestino, non cancellata: l'audio di una riunione non si rifà.
        if (try? FileManager.default.trashItem(at: m.folder, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: m.folder) }
    }

    private func persist(_ m: Meeting) {
        try? FileManager.default.createDirectory(at: m.folder, withIntermediateDirectories: true)
        try? Self.encoder.encode(m).write(to: m.url("meeting.json"), options: .atomic)
    }

    /// Un identificativo libero: due riunioni create nello stesso millisecondo non si sovrascrivono.
    func newID() -> String {
        let base = Meeting.newID()
        var id = base, n = 1
        while FileManager.default.fileExists(atPath: Paths.meetings.appending(path: id).path) || meeting(id) != nil {
            n += 1
            id = "\(base)-\(n)"
        }
        return id
    }

    // MARK: Importazione

    /// Copia i file nell'archivio e li mette in coda: ognuno diventa una riunione.
    func importAudio(_ urls: [URL]) {
        for url in urls {
            let id = newID()
            let file = "source." + (url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased())
            let meeting = Meeting(id: id, title: url.deletingPathExtension().lastPathComponent, createdAt: Date(),
                                  source: .imported, state: .processing, tracks: [.init(kind: .mixed, file: file)],
                                  titleEdited: true)
            do {
                try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: meeting.url(file))
            } catch {
                log.error("import: \(error.localizedDescription)")
                continue
            }
            add(meeting)
            process(id)
        }
    }

    // MARK: Elaborazione

    func process(_ id: String) {
        guard meeting(id) != nil, !queue.contains(id) else { return }
        update(id) { $0.state = .processing; $0.error = nil }
        queue.append(id)
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty { await run(queue.removeFirst()) }
            worker = nil
        }
    }

    private func run(_ id: String) async {
        guard let meeting = meeting(id) else { return }
        progress[id] = Progress(stage: .transcribing, fraction: 0)
        defer { progress[id] = nil }
        do {
            try await waitForModel()
            let language = Prefs.speech
            let result = try await Task.detached(priority: .userInitiated) {
                try await MeetingPipeline.run(meeting, language: language) { stage, done in
                    Task { @MainActor in MeetingStore.shared.progress[id] = Progress(stage: stage, fraction: MeetingPipeline.fraction(stage, done)) }
                }
            }.value
            guard !result.utterances.isEmpty else { throw MeetingError.noSpeech }
            update(id) {
                $0 = result
                $0.state = .ready
                $0.error = nil
                // Dopo l'elaborazione le tracce grezze (alcune centinaia di MB all'ora) non servono più, salvo scelta contraria.
                if $0.source == .recorded, !Prefs.meetingKeepTracks.value { $0.tracks = [] }
            }
            if meeting.source == .recorded, !Prefs.meetingKeepTracks.value {
                for track in meeting.tracks { try? FileManager.default.removeItem(at: meeting.url(track.file)) }
            }
            log.info("riunione \(id): \(result.utterances.count) interventi, \(result.speakers.count) parlanti")
            if Prefs.meetingAutoSummary.value { MeetingAssistant.shared.summarize(id, automatic: true) }
        } catch {
            log.error("riunione \(id): \(error.localizedDescription)")
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
    }

    /// Il modello di dettatura si carica all'avvio: se serve prima, si aspetta.
    private func waitForModel() async throws {
        while true {
            switch Controller.shared.modelState {
            case .ready: return
            case .failed(let why): throw ModelError.unavailable(why)
            case .loading: try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private enum ModelError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case .unavailable(let why) = self { return L("Il modello di riconoscimento non è disponibile: %@", why) }
            return nil
        }
    }
}
