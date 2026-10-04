import SwiftUI

// MARK: - Scorciatoie

struct ShortcutsPage: View {
    @AppStorage(Prefs.hotkey) private var hotkey
    @AppStorage(Prefs.handsFree) private var handsFree
    @AppStorage(Prefs.sendOnInvia) private var sendOnInvia
    @State private var recording = false
    @State private var problem: String?
    private var trigger: Hotkey.Trigger { Hotkey.Trigger(rawValue: hotkey) ?? .rightCommand }

    var body: some View {
        Form {
            Section {
                Picker("Tasto di dettatura", selection: $hotkey) {
                    ForEach(Hotkey.Trigger.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    if !Hotkey.Trigger.allCases.contains(trigger) { Text(trigger.label).tag(hotkey) }
                }
                LabeledContent("Altro tasto o combinazione") {
                    Button(recording ? "Premi i tasti… (Esc annulla)" : "Registra…") { record() }
                }
                Picker("Mani libere", selection: $handsFree) {
                    Text("\(trigger.label) + Spazio").tag(Hotkey.HandsFree.space.rawValue)
                    Text("Doppio tocco di \(trigger.label)").tag(Hotkey.HandsFree.doubleTap.rawValue)
                    Text("Disattivate").tag(Hotkey.HandsFree.off.rawValue)
                }
                LabeledContent("Trasforma il testo selezionato") { Keycaps(trigger.commandKeys) }
                LabeledContent("Re-incolla l'ultima dettatura") { Keycaps(["⌃", "⌥", "V"]) }
            } footer: {
                Text(problem ?? hint).font(.caption).foregroundStyle(problem == nil ? .secondary : Color.orange)
            }

            Section("Comandi vocali") {
                LabeledContent("«a capo»", value: "Nuova riga")
                LabeledContent("«nuovo paragrafo»", value: "Riga vuota")
                Toggle(isOn: $sendOnInvia) {
                    Text("«invia» alla fine preme Invio")
                    Text("Solo nei terminali e negli editor di codice.")
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { if recording { Controller.shared.hotkey.stopRecording() } }
    }

    private func record() {
        guard !recording else { return Controller.shared.hotkey.stopRecording() }
        guard Controller.shared.hotkey.isInstalled else {
            problem = "Per registrare un tasto serve il permesso di Accessibilità (vedi Panoramica)."
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
            return "Tieni premuto ⌘ destro per dettare. Il doppio tocco di ⌘ è anche la scorciatoia di Siri: se la usi, scegli «+ Spazio» per le mani libere."
        case .rightOption: return "Tieni premuto ⌥ destro per dettare: non interferisce con le scorciatoie di ⌘."
        case .rightControl: return "Tieni premuto ⌃ destro per dettare. Molte tastiere esterne ce l'hanno, i MacBook no."
        case .fn:
            return "Se 🌐 apre le emoji o la dettatura di macOS, imposta Impostazioni di Sistema › Tastiera › «Premi 🌐 per» su «Non fare nulla». Sulle tastiere non Apple Fn è gestito dalla tastiera e non arriva al Mac: registra un altro tasto."
        default:
            if trigger.keyCode == 0xB0 {
                return "Tieni premuto 🎤 per dettare. Se apre la dettatura di macOS, disattivala in Impostazioni di Sistema › Tastiera › Dettatura."
            }
            return trigger.isModifierKey
                ? "Tieni premuto \(trigger.label) per dettare. Se lo usi anche nelle scorciatoie, la dettatura si annulla da sola."
                : "Tieni premuto \(trigger.label) per dettare: finché Voce è attivo, questa combinazione non arriva alle altre app."
        }
    }
}
