import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Generale: lingua, avvio, microfono, riconoscimento, avanzate

struct GeneralPage: View {
    @AppStorage(Prefs.appLanguage) private var appLanguage
    @AppStorage(Prefs.speechLanguage) private var speechLanguage
    @AppStorage(Prefs.mediaMode) private var mediaMode
    @AppStorage(Prefs.mediaLevel) private var mediaLevel
    @AppStorage(Prefs.livePreview) private var livePreview
    @AppStorage(Prefs.asrModel) private var asrModel
    @AppStorage(Prefs.warmMic) private var warmMic
    @AppStorage(Prefs.sounds) private var sounds
    @AppStorage(Prefs.restoreClipboardMs) private var restoreClipboardMs
    @AppStorage(Prefs.saveSamples) private var saveSamples
    @AppStorage(Prefs.meetingKeepTracks) private var keepTracks
    @AppStorage(Prefs.vocabBoost) private var vocabBoost
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var micName = Permissions.inputDeviceName

    var body: some View {
        Form {
            Section(L("Lingua")) {
                Picker(selection: $appLanguage) {
                    Text(L("Automatica (come il Mac)")).tag(AppLanguage.system.rawValue)
                    Text("Italiano").tag(AppLanguage.it.rawValue)
                    Text("English").tag(AppLanguage.en.rawValue)
                } label: {
                    Text(L("Lingua dell'app"))
                    Text(L("Menu, finestre e messaggi di Voce."))
                }
                .onChange(of: appLanguage) { _, raw in AppLanguage.apply(AppLanguage(rawValue: raw) ?? .system) }
                Picker(selection: $speechLanguage) {
                    Text(L("Italiano e inglese")).tag(SpeechLanguage.auto.rawValue)
                    Text(L("Solo italiano")).tag(SpeechLanguage.it.rawValue)
                    Text(L("Solo inglese")).tag(SpeechLanguage.en.rawValue)
                } label: {
                    Text(L("Lingua della dettatura"))
                    Text(L("Il riconoscimento capisce entrambe le lingue, anche mescolate. Qui scegli quali comandi vocali valgono: «a capo» o «new line»."))
                }
            }

            Section {
                Toggle(L("Apri all'accensione del Mac"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle(L("Suoni di inizio e fine"), isOn: $sounds)
                Toggle(isOn: $livePreview) {
                    Text(L("Mostra il testo mentre parli"))
                    Text(L("Quello che dici compare sopra la forma d'onda, mentre lo dici. Usa un po' di più il Neural Engine."))
                }
            }

            Section {
                Picker(selection: $mediaMode) {
                    Text(L("Non toccarlo")).tag(MediaMode.off.rawValue)
                    Text(L("Fermalo del tutto")).tag(MediaMode.pause.rawValue)
                    Text(L("Abbassa il volume")).tag(MediaMode.lower.rawValue)
                } label: {
                    Text(L("Audio del Mac mentre detti"))
                    Text(mediaModeHelp)
                }
                if mediaMode == MediaMode.lower.rawValue {
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { Double(mediaLevel) }, set: { mediaLevel = Int($0) }),
                                   in: Double(MediaMode.levelRange.lowerBound)...Double(MediaMode.levelRange.upperBound),
                                   step: Double(MediaMode.levelStep))
                                .frame(width: 180)
                            Text("\(mediaLevel)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    } label: {
                        Text(L("Volume mentre parli"))
                        Text(L("Percentuale del volume che hai impostato: con 20% la musica resta in sottofondo."))
                    }
                }
            }

            Section(L("Microfono")) {
                LabeledContent(L("Ingresso")) {
                    HStack {
                        Text(micName ?? L("Nessuno")).foregroundStyle(.secondary)
                        Button(L("Cambia…")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
                        }
                    }
                }
                Toggle(isOn: $warmMic) {
                    Text(L("Sempre pronto"))
                    Text(L("Se perde le prime sillabe. L'indicatore arancione resta acceso."))
                }
            }

            Section(L("Riconoscimento")) {
                Picker(selection: $asrModel) {
                    Text(L("Parakeet Ultra")).tag(Transcriber.Model.ultra.rawValue)
                    Text(L("Parakeet v3")).tag(Transcriber.Model.v3.rawValue)
                } label: {
                    Text(L("Modello"))
                    Text(L("Ultra è più preciso, stessa velocità. Cambiandolo si scaricano ~700 MB."))
                }
                Toggle(isOn: $vocabBoost) {
                    Text(L("Cerca le parole del Dizionario nell'audio"))
                    Text(L("Più precisione sui nomi, circa 0,1 s in più."))
                }
            }

            Section(L("Avanzate")) {
                Stepper(value: $restoreClipboardMs, in: 100...3000, step: 100) {
                    Text(L("Ripristino appunti dopo %@", secondsText(restoreClipboardMs)))
                    Text(L("Aumentalo se in qualche app viene incollato il contenuto precedente."))
                }
                Toggle(isOn: $saveSamples) {
                    Text(L("Salva le registrazioni"))
                    Text(L("Audio e testo in ~/voce-dataset, per misurare la precisione."))
                }
                Toggle(isOn: $keepTracks) {
                    Text(L("Conserva le tracce delle riunioni"))
                    Text(L("Microfono e audio del Mac separati (circa 230 MB all'ora): servono per rielaborare una riunione."))
                }
                LabeledContent(L("File")) {
                    HStack {
                        Button(L("Registro")) { NSWorkspace.shared.open(Paths.history) }
                        Button(L("Cartella di Voce")) { NSWorkspace.shared.open(Paths.dir) }
                        if saveSamples { Button(L("Registrazioni")) { NSWorkspace.shared.open(Paths.dataset) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { micName = Permissions.inputDeviceName }
    }

    private var mediaModeHelp: String {
        switch MediaMode(rawValue: mediaMode) ?? .lower {
        case .off: return L("Musica e video continuano a suonare mentre parli.")
        case .pause: return L("Musica e video sfumano e si fermano, poi ripartono quando hai finito. Gli altri suoni vengono azzerati.")
        case .lower: return L("Tutto resta in riproduzione, ma più piano: il volume torna com'era quando hai finito.")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("Non è stato possibile: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
