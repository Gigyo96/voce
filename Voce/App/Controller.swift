import AppKit
import AVFoundation

/// Il cuore dell'app: collega tasto, microfono, trascrizione, post-processing e inserimento del testo.
/// Flusso di una dettatura: `start` (tasto premuto) → `cutSegmentIfNeeded` (audio lungo, in background)
/// → `stop` (tasto rilasciato) → `process` (trascrizione + testo finale) → `Paster.insert`.
@MainActor final class Controller: ObservableObject {
    static let shared = Controller()

    enum ModelState: Equatable { case loading(Double), ready, failed(String) }

    @Published private(set) var modelState: ModelState = .loading(0)
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var lastText: String?
    @Published private(set) var history: [History.Entry] = []
    @Published private(set) var permissionsGranted = Permissions.allGranted
    @Published private(set) var hotkeyActive = false

    let recorder = Recorder()
    let hotkey = Hotkey()
    let hud = HUD()
    let mediaPause = MediaPause()
    let livePreview = LivePreview()

    private var mode: Hotkey.Mode = .pushToTalk
    private var maxTimer: Task<Void, Never>?
    private var segmentLoop: Task<Void, Never>?
    private var segmentTasks: [Task<Transcription, Error>] = []
    private var committed = 0   // campioni già affidati ai segmenti
    private var defaultsObserver: NSObjectProtocol?
    private var statusTimer: Timer?
    private var loadedModel: Transcriber.Model?

    func launch() {
        Prefs.migrate()
        MediaPause.recoverIfNeeded()
        HangDetector.start()
        _ = DictionaryStore.shared.current          // crea ~/.voce/dictionary.json al primo avvio
        loadHistory()
        MeetingStore.shared.load()
        hud.levelSource = { [recorder] in recorder.consumeLevel() }

        applyHotkeyPrefs()
        hotkey.onStart = { [weak self] in self?.start($0) }
        hotkey.onModeChange = { [weak self] in self?.changeMode($0) }
        hotkey.onStop = { [weak self] in self?.stop() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.onRepaste = { [weak self] in self?.repaste() }
        hotkey.install()

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else { return }
                self.recorder.warmMic = Prefs.warmMic.value
                self.recorder.prepare()
            }
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.applySettings() } }

        loadModel()
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        // Primo avvio o permessi mancanti: la Panoramica fa da benvenuto e guida ai permessi.
        if !Permissions.allGranted || !Prefs.welcomed.value {
            Prefs.welcomed.value = true
            Windows.show(.overview)
        }
    }

    func loadHistory() {
        history = History.recent()
        lastText = history.last?.final
    }

    /// Permessi e tap si possono perdere mentre l'app gira: l'icona di menu bar lo deve mostrare.
    private func refreshStatus() {
        let granted = Permissions.allGranted
        if granted != permissionsGranted { permissionsGranted = granted }
        if hotkey.isInstalled != hotkeyActive { hotkeyActive = hotkey.isInstalled }
    }

    private func play(_ name: String) {
        guard Prefs.sounds.value, let sound = NSSound(named: name) else { return }
        sound.volume = 0.25
        sound.play()
    }

    private func applyHotkeyPrefs() {
        hotkey.trigger = Prefs.trigger
        hotkey.handsFree = Prefs.handsFreeMode
    }

    private func applySettings() {
        applyHotkeyPrefs()
        if Permissions.microphone { recorder.warmMic = Prefs.warmMic.value }
        if Prefs.model != loadedModel, !isLoading { loadModel() }
    }

    var isLoading: Bool { if case .loading = modelState { return true } else { return false } }

    func loadModel() {
        let model = Prefs.model
        modelState = .loading(0)
        Task {
            do {
                let terms = Prefs.boostTerms(DictionaryStore.shared.current)
                try await Transcriber.shared.load(model, terms: terms) { p in
                    Task { @MainActor in
                        if case .loading = Controller.shared.modelState { Controller.shared.modelState = .loading(p) }
                    }
                }
                loadedModel = model
                modelState = .ready
            } catch {
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Dettatura

    private func start(_ mode: Hotkey.Mode) {
        guard modelState == .ready else {
            log.info("start ignorato: modello non pronto")
            hotkey.reset()
            hud.show(.error(isLoading ? L("Modello in caricamento…") : L("Modello non disponibile")))
            return
        }
        guard Permissions.microphone else {
            hotkey.reset()
            hud.show(.error(L("Serve il permesso Microfono")))
            Windows.show(.overview)
            return
        }
        self.mode = mode
        log.info("start \(String(describing: mode))")
        do { try recorder.start() } catch {
            log.error("recorder.start: \(error.localizedDescription)")
            hotkey.reset()
            hud.show(.error(error.localizedDescription))
            return
        }
        isRecording = true
        let terms = Prefs.boostTerms(DictionaryStore.shared.current)
        Task.detached(priority: .userInitiated) { await Transcriber.shared.prewarm(terms: terms) }
        committed = 0
        segmentTasks = []
        segmentLoop?.cancel()
        segmentLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                self.cutSegmentIfNeeded(terms: terms)
            }
        }
        hud.show(.listening(mode), delay: 0.15)
        if Prefs.livePreview.value {
            livePreview.start(recorder: recorder, language: Prefs.speech, dictionary: DictionaryStore.shared.current) {
                [weak self] text in self?.hud.setLiveText(text)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.15))
            if self?.isRecording == true { self?.play("Tink") }
            // L'audio si ferma solo per una dettatura vera: un tap o ⌘C col ⌘ destro durano meno di minHold.
            try? await Task.sleep(for: .seconds(Hotkey.minHold - 0.15))
            if let self, self.isRecording, !MeetingRecorder.shared.isRecording { self.mediaPause.begin() }
        }
        let limit = max(10, Prefs.maxRecordingSec.value)
        maxTimer?.cancel()
        maxTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.hotkey.reset()
            self.stop()
        }
    }

    /// Se l'audio non ancora trascritto supera la soglia, ne taglia un segmento in una pausa e lo trascrive
    /// in background. I segmenti si concatenano in ordine (ognuno attende il precedente).
    private func cutSegmentIfNeeded(terms: [(term: String, aliases: [String])]) {
        let pending = recorder.peek(from: committed)
        guard Recorder.duration(pending) >= Segmenter.triggerSeconds else { return }
        let cut = Segmenter.cutPoint(pending)
        let segment = Array(pending[..<cut])
        committed += cut
        let previous = segmentTasks.last
        let language = Prefs.speech
        segmentTasks.append(Task.detached(priority: .userInitiated) {
            _ = try? await previous?.value
            return try await Transcriber.shared.transcribe(segment, terms: terms, language: language)
        })
        // L'anteprima dal vivo riparte dopo questo segmento appena è trascritto.
        let task = segmentTasks[segmentTasks.count - 1], upTo = committed, session = livePreview.session
        Task { [weak self] in
            if let tr = try? await task.value { self?.livePreview.segmentFinished(tr.raw, upTo: upTo, session: session) }
        }
        log.info("segmento \(segmentTasks.count): \(String(format: "%.1f", Recorder.duration(segment))) s in background")
    }

    private func changeMode(_ mode: Hotkey.Mode) {
        guard isRecording else { return }
        self.mode = mode
        hud.show(.listening(mode))
    }

    private func cancel() {
        maxTimer?.cancel()
        segmentLoop?.cancel()
        mediaPause.end()
        livePreview.stop()
        segmentTasks = []
        guard isRecording else { return }
        recorder.cancel()
        isRecording = false
        // Esc in mani libere è una scelta esplicita: si conferma. Gli altri annullamenti (tap breve,
        // ⌘ destro usato come modificatore) restano silenziosi.
        if mode == .handsFree { hud.show(.notice(L("Dettatura annullata"), symbol: "xmark")) } else { hud.hide() }
    }

    private func stop() {
        maxTimer?.cancel()
        segmentLoop?.cancel()
        mediaPause.end()
        livePreview.stop()
        guard isRecording else { return }
        let releasedAt = Date()
        let samples = recorder.stop()
        isRecording = false
        Task { log.info("prewarm \(await Transcriber.shared.lastPrewarmMs) ms") }
        log.info("stop: \(samples.count) campioni (\(String(format: "%.2f", Recorder.duration(samples))) s)")

        let threshold = Float(Prefs.silenceRMS.value)
        guard Recorder.duration(samples) >= Hotkey.minHold else { hud.hide(); return }
        guard Recorder.hasVoice(samples, threshold: threshold) else {
            hud.show(.notice(L("Non ho sentito nulla"), symbol: "mic.slash"))
            return
        }
        hud.show(.processing)
        isProcessing = true
        let mode = self.mode
        let segments = segmentTasks, tailStart = min(committed, samples.count)
        segmentTasks = []
        Task { await process(samples, segments: segments, tailStart: tailStart, mode: mode, releasedAt: releasedAt) }
    }

    private func process(_ samples: [Float], segments: [Task<Transcription, Error>] = [], tailStart: Int = 0,
                         mode: Hotkey.Mode, releasedAt: Date) async {
        defer { isProcessing = false }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let profile = Profile.from(bundleID: app)
        let dictionary = DictionaryStore.shared.current

        do {
            // Command Mode: la selezione si legge mentre Parakeet trascrive l'istruzione.
            let terms = Prefs.boostTerms(dictionary)
            let language = Prefs.speech
            let tail = Array(samples[tailStart...])
            async let transcription: Transcription = {
                var parts: [Transcription] = []
                for segment in segments { parts.append(try await segment.value) }
                parts.append(try await Transcriber.shared.transcribe(tail, terms: terms, language: language))
                return Transcription.merge(parts)
            }()
            let selection: String? = mode == .command ? await Paster.copySelection() : nil
            let tr = try await transcription

            var entry = History.Entry(ts: History.iso.string(from: releasedAt), app: app, profile: profile.rawValue,
                                  mode: "\(mode)", raw: tr.raw, boosted: tr.boosted == tr.raw ? nil : tr.boosted,
                                  final: "", ms: 0, audio_ms: Int(Recorder.duration(samples) * 1000),
                                  asr_ms: tr.asrMs + tr.boostMs, boost_ms: tr.boostMs, segments: tr.segments,
                                  llm_ms: nil, llm: false, guardrail: nil)

            let text: String
            var send = false
            if mode == .command {
                guard let rewritten = await runCommand(tr.boosted, on: selection, dictionary: dictionary, entry: &entry) else { return }
                text = rewritten
            } else {
                let llm = profile.usesLLM(Prefs.llmProfiles.value) ? Prefs.llm() : nil
                let pp = await PostProcess.run(raw: tr.boosted, profile: profile, dictionary: dictionary,
                                               sendOnInvia: Prefs.sendOnInvia.value, language: Prefs.speech, llm: llm)
                text = pp.text
                send = pp.send
                entry.llm = pp.llmUsed
                entry.llm_ms = pp.llmMs
                entry.guardrail = pp.guardrail
            }

            guard !text.isEmpty else { hud.show(.notice(L("Nessuna parola riconosciuta"), symbol: "text.badge.xmark")); return }
            await Paster.insert(text, newlineKey: mode == .command ? "return" : profile.newlineKey,
                                pressReturn: send, restoreAfterMs: Prefs.restoreClipboardMs.value)
            entry.ms = Int(Date().timeIntervalSince(releasedAt) * 1000)
            entry.final = text
            lastText = text
            hud.show(.done(text))
            play("Pop")
            History.append(entry)
            history.append(entry)
            if history.count > 500 { history.removeFirst(history.count - 500) }
            if Prefs.saveSamples.value { History.saveSample(samples, text: text, stamp: History.timestamp(releasedAt)) }
        } catch {
            log.error("process: \(error.localizedDescription)")
            hud.show(.error(error.localizedDescription))
        }
    }

    /// Command Mode: l'istruzione dettata trasforma il testo selezionato. `nil` se non c'è nulla da incollare
    /// (il HUD spiega perché).
    private func runCommand(_ spoken: String, on selection: String?, dictionary: PersonalDictionary,
                            entry: inout History.Entry) async -> String? {
        guard let selection, !selection.isEmpty else { hud.show(.error(L("Nessun testo selezionato"))); return nil }
        let instruction = Rules.tidy(dictionary.apply(spoken))
        let config = Prefs.llm(command: true)
        let t0 = Date()
        let text: String
        do {
            text = try await LLMClient.complete(
                system: Prompts.command, user: "ISTRUZIONE: \(instruction)\n\nTESTO:\n\(selection)", config: config,
                maxTokens: LLMClient.maxTokens(for: selection + instruction, floor: 256) * 2)
        } catch {
            log.error("command: \(error.localizedDescription)")
            hud.show(.error(L("Comando: %@", LLMClient.headline(error))))
            return nil
        }
        entry.llm_ms = Int(Date().timeIntervalSince(t0) * 1000)
        entry.llm = true
        entry.profile = "command"
        // Un modello troppo piccolo a volte restituisce la selezione così com'è: incollarla non cambierebbe nulla.
        if PersonalDictionary.key(text) == PersonalDictionary.key(selection) {
            log.info("command: testo invariato (\(config.model))")
            hud.show(.notice(L("Il modello non ha cambiato il testo"), symbol: "equal.circle"))
            return nil
        }
        return text
    }

    func repaste() {
        guard let lastText, !isRecording else { return }
        Task {
            await Paster.insert(lastText, newlineKey: Profile.current.newlineKey,
                                restoreAfterMs: Prefs.restoreClipboardMs.value)
        }
    }
}
