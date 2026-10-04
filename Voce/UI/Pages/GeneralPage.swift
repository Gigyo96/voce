import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Generale: avvio, microfono, riconoscimento, avanzate

struct GeneralPage: View {
    @AppStorage(Prefs.asrModel) private var asrModel
    @AppStorage(Prefs.warmMic) private var warmMic
    @AppStorage(Prefs.sounds) private var sounds
    @AppStorage(Prefs.restoreClipboardMs) private var restoreClipboardMs
    @AppStorage(Prefs.saveSamples) private var saveSamples
    @AppStorage(Prefs.vocabBoost) private var vocabBoost
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var micName = Permissions.inputDeviceName

    var body: some View {
        Form {
            Section {
                Toggle("Apri all'accensione del Mac", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Suoni di inizio e fine", isOn: $sounds)
            }

            Section("Microfono") {
                LabeledContent("Ingresso") {
                    HStack {
                        Text(micName ?? "Nessuno").foregroundStyle(.secondary)
                        Button("Cambia…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
                        }
                    }
                }
                Toggle(isOn: $warmMic) {
                    Text("Sempre pronto")
                    Text("Se perde le prime sillabe. L'indicatore arancione resta acceso.")
                }
            }

            Section("Riconoscimento") {
                Picker(selection: $asrModel) {
                    Text("Parakeet Ultra").tag(Transcriber.Model.ultra.rawValue)
                    Text("Parakeet v3").tag(Transcriber.Model.v3.rawValue)
                } label: {
                    Text("Modello")
                    Text("Ultra è più preciso, stessa velocità. Cambiandolo si scaricano ~700 MB.")
                }
                Toggle(isOn: $vocabBoost) {
                    Text("Cerca le parole del Dizionario nell'audio")
                    Text("Più precisione sui nomi, circa 0,1 s in più.")
                }
            }

            Section("Avanzate") {
                Stepper(value: $restoreClipboardMs, in: 100...3000, step: 100) {
                    Text("Ripristino appunti dopo \(secondsText(restoreClipboardMs))")
                    Text("Aumentalo se in qualche app viene incollato il contenuto precedente.")
                }
                Toggle(isOn: $saveSamples) {
                    Text("Salva le registrazioni")
                    Text("Audio e testo in ~/voce-dataset, per misurare la precisione.")
                }
                LabeledContent("File") {
                    HStack {
                        Button("Registro") { NSWorkspace.shared.open(Paths.history) }
                        Button("Cartella di Voce") { NSWorkspace.shared.open(Paths.dir) }
                        if saveSamples { Button("Registrazioni") { NSWorkspace.shared.open(Paths.dataset) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { micName = Permissions.inputDeviceName }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Non è stato possibile: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
