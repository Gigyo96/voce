import AppKit
import AVFoundation
import Security
import SwiftUI

// MARK: - Impostazioni (§8)

enum Prefs {
    static var defaults: [String: Any] { [
        "llmBaseURL": "http://localhost:1234",
        "llmModel": "qwen3-1.7b",
        "llmTimeoutMs": 1500,
        "llmProfiles": "chat,email",
        "sendOnInvia": false,
        "warmMic": false,
        "restoreClipboardMs": 600,       // ponytail: attesa fissa; le app Electron/Chrome leggono gli appunti in ritardo sotto carico
        "saveSamples": false,
        "vocabBoost": true,              // boosting CTC del dizionario (~+115 ms su M2)
        "hotkey": Hotkey.Trigger.rightCommand.rawValue,
        "handsFree": Hotkey.HandsFree.space.rawValue,
        "asrModel": Transcriber.Model.ultra.rawValue,
        "commandBaseURL": "",            // vuoto = come llmBaseURL
        "commandModel": "",              // vuoto = come llmModel
        "commandTimeoutMs": 6000,
        "silenceRMS": 0.008,
        "maxRecordingSec": 300,
        "sounds": false,
    ] }

    static var d: UserDefaults { .standard }
    static func register() { d.register(defaults: defaults) }

    static func llm(command: Bool = false) -> LLMConfig {
        let base = d.string(forKey: "llmBaseURL") ?? ""
        let model = d.string(forKey: "llmModel") ?? ""
        var cfg = LLMConfig(baseURL: base, model: model, apiKey: nil,
                            timeout: Double(d.integer(forKey: "llmTimeoutMs")) / 1000)
        if command {
            if let b = d.string(forKey: "commandBaseURL"), !b.isEmpty { cfg.baseURL = b }
            if let m = d.string(forKey: "commandModel"), !m.isEmpty { cfg.model = m }
            cfg.timeout = Double(d.integer(forKey: "commandTimeoutMs")) / 1000
        }
        if !isLocal(cfg.baseURL) { cfg.apiKey = Keychain.apiKey(for: cfg.baseURL) }
        return cfg
    }

    /// I comandi usano un servizio diverso da quello della riscrittura.
    static var commandHasOwnService: Bool {
        !(d.string(forKey: "commandBaseURL") ?? "").isEmpty || !(d.string(forKey: "commandModel") ?? "").isEmpty
    }

    /// Una volta per avvio: chiave unica → chiave per servizio; modelli Groq dismessi il 16/08/2026.
    static func migrate() {
        let retired = ["llama-3.1-8b-instant": "openai/gpt-oss-20b", "llama-3.3-70b-versatile": "openai/gpt-oss-120b"]
        for key in ["llmModel", "commandModel"] {
            if let old = d.string(forKey: key), let new = retired[old] { d.set(new, forKey: key) }
        }
        Keychain.migrateLegacy(to: [d.string(forKey: "llmBaseURL") ?? "", d.string(forKey: "commandBaseURL") ?? ""])
    }

    static func isLocal(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host() else { return true }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }
}

/// Chiavi API dei servizi online nel Keychain (§14), una per servizio (host): riscrittura e comandi possono usare
/// provider diversi. Lette una volta e tenute in memoria.
enum Keychain {
    private static let service = "it.dimarcantonio.voce"
    private static let legacyAccount = "llm-api-key"
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func apiKey(for baseURL: String) -> String? { read(account(baseURL)) }
    static func setAPIKey(_ key: String?, for baseURL: String) { write(key, account(baseURL)) }

    private static func account(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return legacyAccount + ":" + (URL(string: trimmed)?.host() ?? trimmed).lowercased()
    }

    /// Prima c'era una chiave sola: va ai servizi online configurati che non ne hanno ancora una.
    static func migrateLegacy(to baseURLs: [String]) {
        guard let old = read(legacyAccount) else { return }
        let online = baseURLs.filter { !$0.isEmpty && !Prefs.isLocal($0) }
        guard !online.isEmpty else { return }
        for url in online where apiKey(for: url) == nil { setAPIKey(old, for: url) }
        write(nil, legacyAccount)
    }

    private static func read(_ account: String) -> String? {
        if let hit = cache[account] { return hit }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        let value = SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
            ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[account] = .some(value)
        return value
    }

    private static func write(_ value: String?, _ account: String) {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        if let value, !value.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        cache[account] = .some(value?.isEmpty == false ? value : nil)
    }
}

// MARK: - Log JSONL e dataset (§8, §10.1)

enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".voce")
    static let url = dir.appending(path: "log.jsonl")
    static let datasetDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "voce-dataset")

    nonisolated(unsafe) static let iso = ISO8601DateFormatter()   // thread-safe

    struct Entry: Codable, Identifiable, Equatable {
        var ts: String
        var app: String
        var profile: String
        var mode: String
        var raw: String
        var boosted: String?
        var final: String
        var ms: Int          // rilascio del tasto → testo incollato
        var audio_ms: Int
        var asr_ms: Int
        var boost_ms: Int?
        var segments: Int?
        var llm_ms: Int?
        var llm: Bool
        var guardrail: String?

        var id: String { ts + "|" + raw }
        var date: Date? { Log.iso.date(from: ts) }
    }

    static func append(_ e: Entry) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? enc.encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Ultime `limit` dettature (dalla coda del file), dalla più vecchia alla più recente.
    static func recent(limit: Int = 300) -> [Entry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 1 << 20
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if size > window { lines.removeFirst() }   // la prima riga è quasi certamente tagliata
        let dec = JSONDecoder()
        return lines.suffix(limit).compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    static func saveSample(_ samples: [Float], text: String, stamp: String) {
        try? FileManager.default.createDirectory(at: datasetDir, withIntermediateDirectories: true)
        try? Recorder.writeWAV(samples, to: datasetDir.appending(path: "\(stamp).wav"))
        try? text.write(to: datasetDir.appending(path: "\(stamp).txt"), atomically: true, encoding: .utf8)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }
}

// MARK: - Controller

@MainActor final class Controller: ObservableObject {
    static let shared = Controller()

    enum ModelState: Equatable { case loading(Double), ready, failed(String) }

    @Published private(set) var modelState: ModelState = .loading(0)
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var lastText: String?
    @Published private(set) var history: [Log.Entry] = []
    @Published private(set) var permissionsGranted = Permissions.allGranted
    @Published private(set) var hotkeyActive = false

    let recorder = Recorder()
    let hotkey = Hotkey()
    let hud = HUD()

    private var mode: Hotkey.Mode = .pushToTalk
    private var startedAt = Date()
    private var maxTimer: Task<Void, Never>?
    private var segmentLoop: Task<Void, Never>?
    private var segmentTasks: [Task<Transcription, Error>] = []
    private var committed = 0   // campioni già affidati ai segmenti
    private var defaultsObserver: NSObjectProtocol?
    private var statusTimer: Timer?

    func launch() {
        Prefs.register()
        Prefs.migrate()
        HangDetector.start()
        _ = DictionaryStore.shared.current          // crea ~/.voce/dictionary.json al primo avvio
        loadHistory()
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
                self.recorder.warmMic = Prefs.d.bool(forKey: "warmMic")
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
        if !Permissions.allGranted || !Prefs.d.bool(forKey: "welcomed") {
            Prefs.d.set(true, forKey: "welcomed")
            Windows.show(.overview)
        }
    }

    func loadHistory() {
        history = Log.recent()
        lastText = history.last?.final
    }

    /// Permessi e tap si possono perdere mentre l'app gira: l'icona di menu bar lo deve mostrare.
    private func refreshStatus() {
        let granted = Permissions.allGranted
        if granted != permissionsGranted { permissionsGranted = granted }
        if hotkey.isInstalled != hotkeyActive { hotkeyActive = hotkey.isInstalled }
    }

    enum Status: Equatable {
        case loading(Double), failed(String), permissions, hotkeyInactive, ready(String), recording, processing

        var menuState: Brand.MenuState {
            switch self {
            case .loading: return .loading
            case .failed, .permissions, .hotkeyInactive: return .attention
            case .ready: return .ready
            case .recording: return .recording
            case .processing: return .processing
            }
        }
        var needsAttention: Bool { menuState == .attention }
        var tint: Color {
            switch self {
            case .loading: return .blue
            case .failed, .permissions, .hotkeyInactive: return .orange
            case .ready: return .green
            case .recording: return .red
            case .processing: return .purple
            }
        }
        var short: String {
            switch self {
            case .loading: return "Preparazione…"
            case .failed: return "Errore del modello"
            case .permissions: return "Mancano permessi"
            case .hotkeyInactive: return "Tasto non attivo"
            case .ready: return "Pronto"
            case .recording: return "In ascolto"
            case .processing: return "Trascrivo…"
            }
        }
        var long: String {
            switch self {
            case .loading(let p): return p > 0 ? "Preparazione del modello… \(Int(p * 100))%" : "Preparazione del modello…"
            case .failed(let e): return "Errore del modello: \(e)"
            case .permissions: return "Mancano dei permessi"
            case .hotkeyInactive: return "Tasto di dettatura non attivo"
            case .ready(let key): return "Pronto · tieni premuto \(key)"
            case .recording: return "In ascolto…"
            case .processing: return "Trascrivo…"
            }
        }
    }

    var status: Status {
        if isRecording { return .recording }
        if isProcessing { return .processing }
        switch modelState {
        case .loading(let p): return .loading(p)
        case .failed(let e): return .failed(e)
        case .ready:
            guard permissionsGranted else { return .permissions }
            guard hotkeyActive else { return .hotkeyInactive }
            return .ready((Hotkey.Trigger(rawValue: Prefs.d.string(forKey: "hotkey") ?? "") ?? .rightCommand).label)
        }
    }

    private func play(_ name: String) {
        guard Prefs.d.bool(forKey: "sounds"), let sound = NSSound(named: name) else { return }
        sound.volume = 0.25
        sound.play()
    }

    private func applyHotkeyPrefs() {
        hotkey.trigger = Hotkey.Trigger(rawValue: Prefs.d.string(forKey: "hotkey") ?? "") ?? .rightCommand
        hotkey.handsFree = Hotkey.HandsFree(rawValue: Prefs.d.string(forKey: "handsFree") ?? "") ?? .space
    }

    private func applySettings() {
        applyHotkeyPrefs()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            recorder.warmMic = Prefs.d.bool(forKey: "warmMic")
        }
        let wanted = Transcriber.Model(rawValue: Prefs.d.string(forKey: "asrModel") ?? "") ?? .ultra
        if wanted != loadedModel, !isLoading { loadModel() }
    }

    private var loadedModel: Transcriber.Model?

    var isLoading: Bool { if case .loading = modelState { return true } else { return false } }

    func loadModel() {
        let model = Transcriber.Model(rawValue: Prefs.d.string(forKey: "asrModel") ?? "") ?? .ultra
        modelState = .loading(0)
        Task {
            do {
                let terms = Prefs.d.bool(forKey: "vocabBoost") ? Transcriber.vocabulary(for: DictionaryStore.shared.current) : []
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
            hud.show(.error(isLoading ? "Modello in caricamento…" : "Modello non disponibile"))
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hotkey.reset()
            hud.show(.error("Serve il permesso Microfono"))
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
        startedAt = Date()
        isRecording = true
        let terms = Prefs.d.bool(forKey: "vocabBoost") ? Transcriber.vocabulary(for: DictionaryStore.shared.current) : []
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
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.15))
            if self?.isRecording == true { self?.play("Tink") }
        }
        let limit = max(10, Prefs.d.integer(forKey: "maxRecordingSec"))
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
        segmentTasks.append(Task.detached(priority: .userInitiated) {
            _ = try? await previous?.value
            return try await Transcriber.shared.transcribe(segment, terms: terms)
        })
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
        segmentTasks = []
        guard isRecording else { return }
        recorder.cancel()
        isRecording = false
        // Esc in mani libere è una scelta esplicita: si conferma. Gli altri annullamenti (tap breve,
        // ⌘ destro usato come modificatore) restano silenziosi.
        if mode == .handsFree { hud.show(.notice("Dettatura annullata", symbol: "xmark")) } else { hud.hide() }
    }

    private func stop() {
        maxTimer?.cancel()
        segmentLoop?.cancel()
        guard isRecording else { return }
        let releasedAt = Date()
        let samples = recorder.stop()
        isRecording = false
        Task { log.info("prewarm \(await Transcriber.shared.lastPrewarmMs) ms") }
        log.info("stop: \(samples.count) campioni (\(String(format: "%.2f", Recorder.duration(samples))) s)")

        let threshold = Float(Prefs.d.double(forKey: "silenceRMS"))
        guard Recorder.duration(samples) >= Hotkey.minHold else { hud.hide(); return }
        guard Recorder.hasVoice(samples, threshold: threshold) else {
            hud.show(.notice("Non ho sentito nulla", symbol: "mic.slash"))
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
        let d = Prefs.d

        do {
            // Command Mode: la selezione si legge mentre Parakeet trascrive l'istruzione.
            let terms = d.bool(forKey: "vocabBoost") ? Transcriber.vocabulary(for: dictionary) : []
            let tail = Array(samples[tailStart...])
            async let transcription: Transcription = {
                var parts: [Transcription] = []
                for segment in segments { parts.append(try await segment.value) }
                parts.append(try await Transcriber.shared.transcribe(tail, terms: terms))
                return Transcription.merge(parts)
            }()
            let selection: String? = mode == .command ? await Paster.copySelection() : nil
            let tr = try await transcription

            var entry = Log.Entry(ts: Log.iso.string(from: releasedAt), app: app, profile: profile.rawValue,
                                  mode: "\(mode)", raw: tr.raw, boosted: tr.boosted == tr.raw ? nil : tr.boosted,
                                  final: "", ms: 0, audio_ms: Int(Recorder.duration(samples) * 1000),
                                  asr_ms: tr.asrMs + tr.boostMs, boost_ms: tr.boostMs, segments: tr.segments,
                                  llm_ms: nil, llm: false, guardrail: nil)

            let text: String
            var send = false
            if mode == .command {
                guard let selection, !selection.isEmpty else { hud.show(.error("Nessun testo selezionato")); return }
                let instruction = Rules.tidy(dictionary.apply(tr.boosted))
                let t0 = Date()
                do {
                    text = try await LLMClient.complete(
                        system: Prompts.command, user: "ISTRUZIONE: \(instruction)\n\nTESTO:\n\(selection)",
                        config: Prefs.llm(command: true),
                        maxTokens: LLMClient.maxTokens(for: selection + instruction, floor: 256) * 2)
                } catch {
                    log.error("command: \(error.localizedDescription)")
                    hud.show(.error("Comando: \(LLMClient.headline(error))"))
                    return
                }
                entry.llm_ms = Int(Date().timeIntervalSince(t0) * 1000)
                entry.llm = true
                entry.profile = "command"
                // Un modello troppo piccolo a volte restituisce la selezione così com'è: incollarla non cambierebbe nulla.
                if PersonalDictionary.key(text) == PersonalDictionary.key(selection) {
                    log.info("command: testo invariato (\(Prefs.llm(command: true).model))")
                    hud.show(.notice("Il modello non ha cambiato il testo", symbol: "equal.circle"))
                    return
                }
            } else {
                let llm = profile.usesLLM(d.string(forKey: "llmProfiles") ?? "") ? Prefs.llm() : nil
                let pp = await PostProcess.run(raw: tr.boosted, profile: profile, dictionary: dictionary,
                                               sendOnInvia: d.bool(forKey: "sendOnInvia"), llm: llm)
                text = pp.text
                send = pp.send
                entry.llm = pp.llmUsed
                entry.llm_ms = pp.llmMs
                entry.guardrail = pp.guardrail
            }

            guard !text.isEmpty else { hud.show(.notice("Nessuna parola riconosciuta", symbol: "text.badge.xmark")); return }
            await Paster.insert(text, newlineKey: mode == .command ? "return" : profile.newlineKey,
                                pressReturn: send, restoreAfterMs: d.integer(forKey: "restoreClipboardMs"))
            entry.ms = Int(Date().timeIntervalSince(releasedAt) * 1000)
            entry.final = text
            lastText = text
            hud.show(.done(text))
            play("Pop")
            Log.append(entry)
            history.append(entry)
            if history.count > 500 { history.removeFirst(history.count - 500) }
            if d.bool(forKey: "saveSamples") { Log.saveSample(samples, text: text, stamp: Log.timestamp(releasedAt)) }
        } catch {
            log.error("process: \(error.localizedDescription)")
            hud.show(.error(error.localizedDescription))
        }
    }

    func repaste() {
        guard let lastText, !isRecording else { return }
        Task {
            await Paster.insert(lastText, newlineKey: Profile.current.newlineKey,
                                restoreAfterMs: Prefs.d.integer(forKey: "restoreClipboardMs"))
        }
    }
}

// MARK: - Diagnostica

/// Se il thread principale non risponde per 3 s salva un campionamento in `~/.voce/hang-<ts>.txt` (una volta per avvio):
/// un'interfaccia bloccata non lascia crash report, così resta la traccia di dove era fermo.
enum HangDetector {
    static func start() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                let pong = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { pong.signal() }
                guard pong.wait(timeout: .now() + 3) == .timedOut else { continue }
                try? FileManager.default.createDirectory(at: Log.dir, withIntermediateDirectories: true)
                let out = Log.dir.appending(path: "hang-\(Log.timestamp()).txt")
                log.error("interfaccia bloccata da 3 s: campionamento in \(out.path)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(getpid())", "2", "-file", out.path]
                try? p.run()
                p.waitUntilExit()
                return
            }
        }
    }
}

// MARK: - Permessi

enum Permissions {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var allGranted: Bool { microphone && Hotkey.hasAccessibility && Hotkey.hasInputMonitoring }
    static var inputDeviceName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

// MARK: - CLI (usata da tools/eval.py)

enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        var model = Transcriber.Model.ultra
        var boost = true
        var segmented = false
        var dictPath: String?
        var files: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model": i += 1; model = Transcriber.Model(rawValue: args[safe: i] ?? "") ?? .ultra
            case "--no-boost": boost = false
            case "--segmented": segmented = true
            case "--dict": i += 1; dictPath = args[safe: i]
            default: files.append(args[i])
            }
            i += 1
        }
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("uso: Voce transcribe [--model ultra|v3] [--no-boost] [--segmented] [--dict file.json] file.wav…\n".utf8))
            return 2
        }
        var dictionary = PersonalDictionary.load()
        if let dictPath, let data = FileManager.default.contents(atPath: dictPath),
           let custom = try? JSONDecoder().decode(PersonalDictionary.self, from: data) { dictionary = custom }

        do {
            try await Transcriber.shared.load(model)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for file in files {
                let samples = try Transcriber.loadAudio(file)
                let terms = boost ? Transcriber.vocabulary(for: dictionary) : []
                var tr: Transcription
                if segmented {
                    // Stessa logica dell'app: tagli nelle pause ogni volta che l'audio pendente supera la soglia.
                    var parts: [Transcription] = []
                    var rest = samples[...]
                    while Recorder.duration(Array(rest)) >= Segmenter.triggerSeconds {
                        let cut = Segmenter.cutPoint(Array(rest))
                        parts.append(try await Transcriber.shared.transcribe(Array(rest.prefix(cut)), terms: terms))
                        rest = rest.dropFirst(cut)
                    }
                    parts.append(try await Transcriber.shared.transcribe(Array(rest), terms: terms))
                    tr = Transcription.merge(parts)
                } else {
                    tr = try await Transcriber.shared.transcribe(samples, terms: terms)
                }
                let ruled = Rules.apply(tr.boosted, profile: .agentIDE, sendOnInvia: false)
                let final = boost ? Rules.tidy(dictionary.apply(ruled.text)) : ruled.text
                let row = ["file": file, "model": model.rawValue, "boost": boost ? "1" : "0",
                           "raw": tr.raw, "boosted": tr.boosted, "final": final, "asr_ms": String(tr.asrMs),
                           "boost_ms": String(tr.boostMs), "segments": String(tr.segments)]
                FileHandle.standardOutput.write(try enc.encode(row) + Data("\n".utf8))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("errore: \(error)\n".utf8))
            return 1
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
