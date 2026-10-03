import AppKit
import SwiftUI

struct AIStateLabel: View {
    let state: AIStatus.State
    var okText = "Collegato: il servizio risponde e il modello è disponibile."

    var body: some View {
        switch state {
        case .unknown, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Controllo il servizio…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .ok:
            line(okText, "checkmark.circle.fill", .green)
        case .failed(let why):
            line(why, "exclamationmark.triangle.fill", .orange)
        }
    }

    private func line(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

// MARK: - Editor di un servizio (righe di un Form): usato per la riscrittura e, se dedicato, per i comandi

struct AIServiceEditor: View {
    enum Role { case main, command }

    @Binding var baseURL: String
    @Binding var model: String
    let role: Role
    let timeoutMs: Int
    @ObservedObject private var status = AIStatus.shared
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var provider: LLMProvider { .matching(baseURL) }
    private var state: AIStatus.State { role == .main ? status.main : status.command }
    private var models: [String] { status.models[AIStatus.key(baseURL)] ?? [] }
    private var online: Bool { !Prefs.isLocal(baseURL) }
    private var placeholder: String {
        let m = role == .main ? provider.model : provider.commandModel
        return m.isEmpty ? "nome-del-modello" : m
    }

    var body: some View {
        Picker(selection: providerBinding) {
            Section("Sul tuo Mac · gratis, il testo non esce dal computer") {
                ForEach(LLMProvider.onMac) { Text($0.name).tag($0) }
            }
            Section("Online · serve una chiave API") {
                ForEach(LLMProvider.online) { Text($0.name).tag($0) }
            }
            Divider()
            Text(LLMProvider.custom.name).tag(LLMProvider.custom)
        } label: {
            Text("Servizio")
            Text(markdown(provider.blurb))
        }

        if provider == .custom {
            TextField(text: $baseURL, prompt: Text("http://localhost:8080/v1")) {
                Text("Indirizzo")
                Text("L'indirizzo base dell'API, di solito termina con /v1.")
            }
        }

        if online {
            SecureField(text: $key, prompt: Text("incolla qui la chiave")) {
                Text("Chiave API")
                Text(markdown(keyHelp))
            }
        }

        LabeledContent {
            HStack(spacing: 6) {
                TextField("Modello", text: $model, prompt: Text(placeholder)).labelsHidden()
                if !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { m in Button(m) { model = m } }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Scegli tra i modelli disponibili in questo servizio")
                }
            }
        } label: {
            Text("Modello")
            Text(role == .main ? "Ne basta uno piccolo e veloce." : "Meglio uno capace di seguire istruzioni.")
        }

        HStack(alignment: .top, spacing: 8) {
            if let testResult {
                Label {
                    Text(testResult.text).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                } icon: {
                    Image(systemName: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult.ok ? .green : .red)
                }
            } else {
                AIStateLabel(state: state)
            }
            Spacer(minLength: 8)
            Button(testing ? "Provo…" : "Prova") { test() }
                .disabled(testing)
                .help(role == .main ? "Fa riscrivere una frase d'esempio" : "Fa tradurre una frase d'esempio")
        }
        .onAppear { key = Keychain.apiKey(for: baseURL) ?? "" }
        .onChange(of: baseURL) { _, url in
            key = Keychain.apiKey(for: url) ?? ""
            testResult = nil
        }
        .onChange(of: model) { _, _ in testResult = nil }
        .onChange(of: key) { _, k in
            guard k != (Keychain.apiKey(for: baseURL) ?? "") else { return }
            Keychain.setAPIKey(k, for: baseURL)
            testResult = nil
            status.refresh()
        }
    }

    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { provider }, set: { p in
            guard p != provider else { return }
            baseURL = p.baseURL   // "Altro": indirizzo vuoto, da scrivere
            model = role == .main ? p.model : p.commandModel
        })
    }

    private var keyHelp: String {
        var s = "Salvata nel Portachiavi del Mac."
        if let url = provider.setupURL, let host = url.host() { s += " Non ce l'hai? [Creala su \(host)](\(url.absoluteString))" }
        return s
    }

    private func test() {
        testing = true
        testResult = nil
        // Timeout largo: la prima richiesta a un servizio sul Mac carica il modello in memoria.
        let cfg = LLMConfig(baseURL: baseURL, model: model, apiKey: online ? Keychain.apiKey(for: baseURL) : nil, timeout: 30)
        let role = self.role, limit = timeoutMs
        let t0 = Date()
        Task {
            defer { testing = false }
            do {
                let out: String
                switch role {
                case .main:
                    out = try await LLMClient.complete(system: Prompts.cleanup(profile: .chat, terms: []),
                                                       user: "TRASCRITTO: \(AIExample.spoken)", config: cfg, maxTokens: 96)
                case .command:
                    out = try await LLMClient.complete(system: Prompts.command,
                                                       user: "ISTRUZIONE: \(AIExample.instruction)\n\nTESTO:\n\(AIExample.selection)",
                                                       config: cfg, maxTokens: 256)
                }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                var text = "Risposta in \(secondsText(ms)): «\(out.replacingOccurrences(of: "\n", with: " "))»"
                if ms > limit {
                    text += "\nPiù lenta dell'attesa massima (\(secondsText(limit))): riprova, la prima richiesta carica il modello, oppure aumentala."
                }
                testResult = (true, text)
                status.refresh(delay: .zero)
            } catch {
                testResult = (false, LLMClient.friendly(error))
            }
        }
    }
}

// MARK: - Pagina "Funzioni AI"

struct AIPage: View {
    @AppStorage("hotkey") private var hotkey = Hotkey.Trigger.rightCommand.rawValue
    @AppStorage("llmBaseURL") private var llmBaseURL = "http://localhost:1234"
    @AppStorage("llmModel") private var llmModel = "qwen3-1.7b"
    @AppStorage("llmTimeoutMs") private var llmTimeoutMs = 1500
    @AppStorage("llmProfiles") private var llmProfiles = "chat,email"
    @AppStorage("commandBaseURL") private var commandBaseURL = ""
    @AppStorage("commandModel") private var commandModel = ""
    @AppStorage("commandTimeoutMs") private var commandTimeoutMs = 6000
    @ObservedObject private var status = AIStatus.shared
    private var trigger: Hotkey.Trigger { Hotkey.Trigger(rawValue: hotkey) ?? .rightCommand }
    private var dedicated: Bool { !commandBaseURL.isEmpty || !commandModel.isEmpty }

    var body: some View {
        Form {
            Section {
                AIServiceEditor(baseURL: $llmBaseURL, model: $llmModel, role: .main, timeoutMs: llmTimeoutMs)
            } header: {
                Text("Servizio")
            } footer: {
                footer("Facoltativo: la dettatura funziona sempre senza. Al servizio va solo il testo, mai l'audio; le chiavi restano nel Portachiavi.")
            }

            Section {
                profileToggle("chat", "Messaggi", "Slack, Discord, Telegram, WhatsApp")
                profileToggle("email", "Email", "Mail, Outlook")
                profileToggle("plain", "Altre app", "Note, browser, documenti")
                Stepper(value: $llmTimeoutMs, in: 500...10_000, step: 250) {
                    Text("Attesa massima \(secondsText(llmTimeoutMs))")
                    Text("Oltre, incolla il testo senza riscriverlo.")
                }
            } header: {
                Text("Riscrittura")
            } footer: {
                footer("Sistema punteggiatura, ripensamenti e tono: «\(AIExample.spoken)» → «\(AIExample.rewritten)». Mai nei terminali e negli editor di codice.")
            }

            Section {
                LabeledContent("Scorciatoia") { Keycaps(trigger.commandKeys) }
                Picker("Servizio", selection: Binding(get: { dedicated }, set: { setDedicated($0) })) {
                    Text("Lo stesso della riscrittura").tag(false)
                    Text("Un servizio dedicato").tag(true)
                }
                if dedicated {
                    AIServiceEditor(baseURL: $commandBaseURL, model: $commandModel, role: .command, timeoutMs: commandTimeoutMs)
                } else {
                    AIStateLabel(state: status.main, okText: "Usa \(LLMProvider.describe(llmBaseURL, llmModel)).")
                }
                Stepper("Attesa massima \(secondsText(commandTimeoutMs))", value: $commandTimeoutMs, in: 2000...30_000, step: 1000)
            } header: {
                Text("Comandi sul testo selezionato")
            } footer: {
                footer("Seleziona un testo, tieni premuti i tasti e di' cosa farne: «traduci in inglese», «rendilo più formale». Per i comandi conviene un modello capace (es. GPT-OSS 120B su Groq o Claude).")
            }
        }
        .formStyle(.grouped)
        .onAppear { status.refresh(delay: .zero) }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func profileToggle(_ profile: String, _ title: String, _ apps: String) -> some View {
        Toggle(isOn: Binding(get: { Profile(rawValue: profile)?.usesLLM(llmProfiles) ?? false }, set: { on in
            var set = llmProfiles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            set.removeAll { $0 == profile }
            if on { set.append(profile) }
            llmProfiles = set.joined(separator: ",")
        })) {
            Text(title)
            Text(apps)
        }
    }

    private func setDedicated(_ on: Bool) {
        if on {
            let p = LLMProvider.matching(llmBaseURL)
            commandBaseURL = llmBaseURL
            commandModel = p == .custom ? llmModel : p.commandModel
        } else {
            commandBaseURL = ""
            commandModel = ""
        }
    }
}
