import SwiftUI

// MARK: - Scorciatoie

struct ShortcutsPage: View {
    @AppStorage(Prefs.hotkey) private var hotkey
    @AppStorage(Prefs.handsFree) private var handsFree
    @AppStorage(Prefs.sendOnInvia) private var sendOnInvia
    @AppStorage(Prefs.speechLanguage) private var speechLanguage   // i comandi vocali mostrati dipendono dalla lingua
    @State private var recording = false
    @State private var problem: String?
    private var trigger: Hotkey.Trigger { Hotkey.Trigger(rawValue: hotkey) ?? .rightCommand }

    var body: some View {
        Form {
            Section {
                Picker(L("Tasto di dettatura"), selection: $hotkey) {
                    ForEach(Hotkey.Trigger.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    if !Hotkey.Trigger.allCases.contains(trigger) { Text(trigger.label).tag(hotkey) }
                }
                LabeledContent(L("Altro tasto o combinazione")) {
                    Button(recording ? L("Premi i tasti… (Esc annulla)") : L("Registra…")) { record() }
                }
                Picker(L("Mani libere"), selection: $handsFree) {
                    Text(trigger.label + " + " + L("Spazio")).tag(Hotkey.HandsFree.space.rawValue)
                    Text(L("Doppio tocco di %@", trigger.label)).tag(Hotkey.HandsFree.doubleTap.rawValue)
                    Text(L("Disattivate")).tag(Hotkey.HandsFree.off.rawValue)
                }
                LabeledContent(L("Trasforma il testo selezionato")) { Keycaps(trigger.commandKeys) }
                LabeledContent(L("Re-incolla l'ultima dettatura")) { Keycaps(["⌃", "⌥", "V"]) }
            } footer: {
                Text(problem ?? hint).font(.caption).foregroundStyle(problem == nil ? .secondary : Color.orange)
            }

            Section(L("Comandi vocali")) {
                LabeledContent(VoiceCommand.newline.spoken, value: L("Nuova riga"))
                LabeledContent(VoiceCommand.paragraph.spoken, value: L("Riga vuota"))
                Toggle(isOn: $sendOnInvia) {
                    Text(L("%@ alla fine preme Invio", VoiceCommand.send.spoken))
                    Text(L("Solo nei terminali e negli editor di codice."))
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { if recording { Controller.shared.hotkey.stopRecording() } }
    }

    private func record() {
        guard !recording else { return Controller.shared.hotkey.stopRecording() }
        guard Controller.shared.hotkey.isInstalled else {
            problem = L("Per registrare un tasto serve il permesso di Accessibilità (vedi Panoramica).")
            return
        }
        recording = true
        problem = nil
        Controller.shared.hotkey.record { t in
            recording = false
            guard let t else { return }
            if let p = t.problem { problem = p } else { hotkey = t.rawValue }
        }
    }

    private var hint: String {
        switch trigger {
        case .rightCommand:
            return L("Tieni premuto ⌘ destro per dettare. Il doppio tocco di ⌘ è anche la scorciatoia di Siri: se la usi, scegli «+ Spazio» per le mani libere.")
        case .rightOption: return L("Tieni premuto ⌥ destro per dettare: non interferisce con le scorciatoie di ⌘.")
        case .rightControl: return L("Tieni premuto ⌃ destro per dettare. Molte tastiere esterne ce l'hanno, i MacBook no.")
        case .fn:
            return L("Se 🌐 apre le emoji o la dettatura di macOS, imposta Impostazioni di Sistema › Tastiera › «Premi 🌐 per» su «Non fare nulla». Sulle tastiere non Apple Fn è gestito dalla tastiera e non arriva al Mac: registra un altro tasto.")
        default:
            if trigger.keyCode == 0xB0 {
                return L("Tieni premuto 🎤 per dettare. Se apre la dettatura di macOS, disattivala in Impostazioni di Sistema › Tastiera › Dettatura.")
            }
            return trigger.isModifierKey
                ? L("Tieni premuto %@ per dettare. Se lo usi anche nelle scorciatoie, la dettatura si annulla da sola.", trigger.label)
                : L("Tieni premuto %@ per dettare: finché Voce è attivo, questa combinazione non arriva alle altre app.", trigger.label)
        }
    }
}
