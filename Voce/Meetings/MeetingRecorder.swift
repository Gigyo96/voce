@preconcurrency import AVFoundation

/// Registra una riunione: il microfono (la tua voce) e l'audio del Mac (gli altri) in due tracce separate su disco.
/// Tenerle separate dà due cose: chi sei tu lo sai senza indovinare, e le voci degli altri si separano per parlante
/// senza la tua in mezzo. Alla fine la riunione passa a `MeetingStore.process`.
@MainActor final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var isRecording = false
    /// Secondi di registrazione (cambia una volta al secondo: la barra dei menu lo mostra).
    @Published private(set) var seconds = 0
    /// Un avviso che non ferma la registrazione (audio del Mac non disponibile…).
    @Published private(set) var warning: String?
    /// L'audio del Mac si sta registrando davvero (può mancare: permesso negato, nessuna uscita, scelta dell'utente).
    @Published private(set) var systemAvailable = false
    /// Titolo e appunti, modificabili mentre si registra; finiscono nella riunione allo stop.
    @Published var title = ""
    @Published var notes = ""
    /// Livelli recenti per le forme d'onda: separati, così il cambio a 10 Hz non ridisegna il resto dell'app.
    let levels = RecordingLevels()
    @Published var micMuted = false { didSet { micWriter?.setMuted(micMuted) } }
    @Published var systemMuted = false { didSet { systemWriter?.setMuted(systemMuted) } }

    private var meeting: Meeting?
    private var micWriter: TrackWriter?
    private var systemWriter: TrackWriter?
    private var engine: AVAudioEngine?
    private var micConverter: PCMConverter?
    private var tap: SystemAudioTap?
    private var timer: Timer?
    private var startedAt = Date()
    private(set) var micDevice = ""
    private(set) var outputDevice = ""
    private var configObserver: NSObjectProtocol?
    private var systemSilenceChecked = false

    func start() {
        guard !isRecording else { return }
        guard Permissions.microphone else {
            warning = L("Serve il permesso Microfono.")
            Windows.show(.overview)
            return
        }
        let id = MeetingStore.shared.newID()
        let captureSystem = Prefs.meetingCaptureSystem.value
        var meeting = Meeting(id: id, title: Meeting.defaultTitle(), createdAt: Date(), source: .recorded, state: .recording,
                              tracks: [.init(kind: .mic, file: "mic.caf")] + (captureSystem ? [.init(kind: .system, file: "system.caf")] : []))
        do {
            try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
            micWriter = try TrackWriter(url: meeting.url("mic.caf"))
            if captureSystem { systemWriter = try TrackWriter(url: meeting.url("system.caf")) }
            try startMic()
        } catch {
            log.error("riunione: \(error.localizedDescription)")
            warning = error.localizedDescription
            discard(meeting)
            return
        }
        micWriter?.setMuted(micMuted)
        systemWriter?.setMuted(systemMuted)

        // Prima il microfono, poi il tap: con le cuffie Bluetooth il contrario lascia il microfono muto.
        warning = nil
        micDevice = Permissions.inputDeviceName ?? ""
        outputDevice = SystemAudio.defaultOutput.flatMap(SystemAudio.name) ?? ""
        systemAvailable = false
        if let systemWriter {
            let tap = SystemAudioTap { samples, host in systemWriter.append(samples, hostTime: host) }
            do { try tap.start(); self.tap = tap; systemAvailable = true } catch {
                log.error("system tap: \(error.localizedDescription)")
                warning = L("Non riesco a registrare l'audio del Mac (%@): registro solo il microfono.", error.localizedDescription)
                self.systemWriter = nil
                systemWriter.close()
                try? FileManager.default.removeItem(at: systemWriter.url)
                meeting.tracks.removeAll { $0.kind == .system }
            }
        }

        MeetingStore.shared.add(meeting)
        self.meeting = meeting
        startedAt = Date()
        seconds = 0
        title = meeting.title
        notes = ""
        levels.reset()
        systemSilenceChecked = false
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log.info("riunione \(id): registrazione iniziata")
    }

    /// Ferma, chiude i file, allinea le tracce e avvia l'elaborazione. Restituisce la riunione creata.
    @discardableResult func stop() -> String? {
        guard isRecording, var meeting else { return nil }
        isRecording = false
        timer?.invalidate()
        timer = nil
        shutdownCapture()

        micWriter?.close()
        systemWriter?.close()
        // Microfono e tap partono con qualche millisecondo di scarto: la traccia che inizia dopo si fa slittare.
        let starts = [Meeting.Track.Kind.mic: micWriter?.firstHostTime, .system: systemWriter?.firstHostTime].compactMapValues { $0 }
        let zero = starts.values.min() ?? 0
        for i in meeting.tracks.indices {
            if let first = starts[meeting.tracks[i].kind] {
                meeting.tracks[i].offset = AVAudioTime.seconds(forHostTime: first) - AVAudioTime.seconds(forHostTime: zero)
            }
        }
        // Una traccia senza nemmeno un campione non serve.
        meeting.tracks.removeAll { track in
            (track.kind == .mic ? micWriter?.seconds : systemWriter?.seconds).map { $0 < 0.5 } ?? true
        }
        meeting.duration = max(micWriter?.seconds ?? 0, systemWriter?.seconds ?? 0)
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, clean != meeting.title { meeting.title = clean; meeting.titleEdited = true }
        let jotted = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.notes = jotted.isEmpty ? nil : jotted
        log.info("riunione \(meeting.id): registrazione finita (\(Int(meeting.duration)) s)")

        let id = meeting.id
        micWriter = nil
        systemWriter = nil
        self.meeting = nil
        guard !meeting.tracks.isEmpty else {
            warning = L("Non è stato registrato nulla.")
            discard(meeting)
            MeetingStore.shared.delete(id)
            return nil
        }
        MeetingStore.shared.update(id) { $0 = meeting }
        MeetingStore.shared.process(id)
        return id
    }

    /// Scarta la registrazione: niente viene salvato.
    func cancel() {
        guard isRecording, let meeting else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        discard(meeting)
        MeetingStore.shared.delete(meeting.id)
        self.meeting = nil
        log.info("riunione \(meeting.id): registrazione scartata")
    }

    /// Chiusura dell'app durante la registrazione: salva quel che c'è, la riunione si potrà elaborare al prossimo avvio.
    func stopForQuit() {
        stop()
    }

    // MARK: Microfono

    private func startMic() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        try installMicTap()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reconfigureMic() } }
    }

    private func installMicTap() throws {
        guard let engine, let writer = micWriter else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = PCMConverter(from: format) else { throw RecorderError.noInput }
        micConverter = converter
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format, block: Self.tapBlock(converter, writer))
    }

    /// Il tap gira sul thread audio: va creato fuori dall'isolamento di `@MainActor` (vedi `SystemAudioTap.ioBlock`).
    private nonisolated static func tapBlock(_ converter: PCMConverter, _ writer: TrackWriter) -> AVAudioNodeTapBlock {
        { buffer, when in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { writer.append(samples, hostTime: when.hostTime) }
        }
    }

    /// Cuffie collegate o scollegate: il formato d'ingresso cambia, l'engine si ferma e si riparte col nuovo.
    private func reconfigureMic() {
        guard isRecording, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installMicTap()
            try engine.start()
        } catch {
            log.error("riunione: microfono non riavviato: \(error.localizedDescription)")
            warning = L("Il microfono si è fermato: %@", error.localizedDescription)
        }
    }

    // MARK: Stato

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt)
        if Int(elapsed) != seconds { seconds = Int(elapsed) }
        levels.push(mic: micWriter?.consumeLevel() ?? 0, system: systemWriter?.consumeLevel() ?? 0)
        // Silenzio *esatto* dall'audio del Mac mentre qualcosa suona: il permesso «Registrazione audio di sistema» manca.
        if !systemSilenceChecked, elapsed > 8, let systemWriter {
            systemSilenceChecked = true
            if !systemWriter.hasSignal, !SystemAudio.playingBundleIDs().isEmpty {
                warning = L("Dal Mac non arriva audio. Controlla il permesso «Registrazione audio di sistema» per Voce in Impostazioni di Sistema › Privacy e sicurezza.")
            }
        }
    }

    private func shutdownCapture() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        micConverter = nil
        tap?.stop()
        tap = nil
        systemAvailable = false
    }

    private func discard(_ meeting: Meeting) {
        shutdownCapture()
        micWriter?.close()
        systemWriter?.close()
        micWriter = nil
        systemWriter = nil
        try? FileManager.default.removeItem(at: meeting.folder)
    }

    func dismissWarning() { warning = nil }

    /// Solo per `Voce snapshot`: uno stato di registrazione d'esempio, senza toccare l'audio.
    func previewState(seconds: Int, mic: String, output: String) {
        self.seconds = seconds
        systemAvailable = true
        micDevice = mic
        outputDevice = output
        title = Meeting.defaultTitle()
        notes = "Obiettivo: chiudere la data del lancio. Partecipanti: Marco (prodotto), Luca (marketing)."
        for i in 0..<RecordingLevels.count {
            levels.push(mic: i > 40 ? 0.03 * Float(abs(sin(Double(i) / 3))) : 0.002, system: 0.05 * Float(abs(sin(Double(i) / 2.1))) + 0.004)
        }
    }
}

/// Gli ultimi livelli di microfono e audio del Mac (uno ogni 100 ms) per le forme d'onda.
@MainActor final class RecordingLevels: ObservableObject {
    static let count = 80   // 8 secondi
    @Published private(set) var mic = [Float](repeating: 0, count: RecordingLevels.count)
    @Published private(set) var system = [Float](repeating: 0, count: RecordingLevels.count)

    func push(mic level: Float, system other: Float) {
        mic.removeFirst(); mic.append(level)
        system.removeFirst(); system.append(other)
    }

    func reset() {
        mic = [Float](repeating: 0, count: Self.count)
        system = mic
    }
}
