import AppKit
import AVFoundation
import SwiftUI

// MARK: - Panoramica: stato, cosa manca per partire, come si usa, cosa sa fare Voce

struct OverviewPage: View {
    @ObservedObject private var controller = Controller.shared
    @ObservedObject private var ai = AIStatus.shared
    @ObservedObject private var nav = Navigation.shared
    @AppStorage("hotkey") private var hotkey = Hotkey.Trigger.rightCommand.rawValue
    @AppStorage("handsFree") private var handsFree = Hotkey.HandsFree.space.rawValue
    @AppStorage("llmProfiles") private var llmProfiles = "chat,email"
    @AppStorage("llmBaseURL") private var llmBaseURL = "http://localhost:1234"
    @AppStorage("commandBaseURL") private var commandBaseURL = ""
    @State private var mic = Permissions.microphone
    @State private var ax = Hotkey.hasAccessibility
    @State private var input = Hotkey.hasInputMonitoring
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var trigger: Hotkey.Trigger { Hotkey.Trigger(rawValue: hotkey) ?? .rightCommand }
    private var ready: Bool { mic && ax && input && controller.modelState == .ready }

    var body: some View {
        Form {
            Section { header }
            if !ready { setup }
            usage
            features
            today
        }
        .formStyle(.grouped)
        .onAppear { ai.refresh(delay: .zero) }
        .onReceive(timer) { _ in
            mic = Permissions.microphone
            ax = Hotkey.hasAccessibility
            input = Hotkey.hasInputMonitoring
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppLogo(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Voce").font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(controller.status.tint).frame(width: 7, height: 7)
                    Text(controller.status.long).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Prima di iniziare

    private var setup: some View {
        Section {
            permission("Microfono", "mic.fill", .red, ok: mic, why: "Per ascoltarti. L'audio resta sul Mac.") {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                Permissions.open("Privacy_Microphone")
            }
            permission("Accessibilità", "accessibility", .blue, ok: ax, why: "Per sentire il tasto e incollare il testo.") {
                Hotkey.requestAccessibility()
                Permissions.open("Privacy_Accessibility")
            }
            permission("Monitoraggio input", "keyboard.fill", .gray, ok: input, why: "Per il tasto anche quando Voce è in secondo piano.") {
                Hotkey.requestInputMonitoring()
                Permissions.open("Privacy_ListenEvent")
            }
            row("Modello vocale", "waveform", .pink, subtitle: modelSubtitle) {
                switch controller.modelState {
                case .loading(let p): ProgressView(value: p).frame(width: 90)
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Button("Riprova") { controller.loadModel() }
                }
            }
        } header: {
            Text("Prima di iniziare")
        }
    }

    private var modelSubtitle: String {
        switch controller.modelState {
        case .loading: return "Parakeet, ~700 MB solo la prima volta."
        case .ready: return "Pronto, funziona senza internet."
        case .failed(let e): return e
        }
    }

    private func permission(_ title: String, _ symbol: String, _ color: Color, ok: Bool, why: String,
                            action: @escaping () -> Void) -> some View {
        row(title, symbol, color, subtitle: why) {
            if ok { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { Button("Concedi…", action: action) }
        }
    }

    private func row<Trailing: View>(_ title: String, _ symbol: String, _ color: Color, subtitle: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        LabeledContent {
            trailing()
        } label: {
            Label {
                Text(title)
                Text(subtitle)
            } icon: {
                IconTile(symbol: symbol, color: color)
            }
        }
    }

    // MARK: Come si usa

    private var usage: some View {
        Section {
            LabeledContent("Detta: tieni premuto, parla, rilascia") { Keycaps([trigger.label]) }
            if let mode = Hotkey.HandsFree(rawValue: handsFree), mode != .off {
                LabeledContent("Mani libere (tocca il tasto per finire)") { Keycaps(mode.keys(trigger)) }
            }
            LabeledContent("Trasforma il testo selezionato") { Keycaps(trigger.commandKeys) }
            LabeledContent("Re-incolla l'ultima dettatura") { Keycaps(["⌃", "⌥", "V"]) }
        } header: {
            HStack {
                Text("Come si usa")
                Spacer()
                Button("Cambia scorciatoie…") { nav.page = .shortcuts }.buttonStyle(.link).font(.caption)
            }
        } footer: {
            Text("Funziona in ogni app. Mentre detti puoi dire «a capo» e «nuovo paragrafo».")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Cosa sa fare Voce: ogni funzione con il suo stato, un clic porta dove si configura

    private var features: some View {
        Section {
            feature("Dizionario", "character.book.closed.fill", .teal,
                    "Nomi e termini tecnici scritti come vuoi tu", value: (dictionarySummary, nil), page: .dictionary)
            feature("Riscrittura con AI", "text.badge.checkmark", .blue,
                    "Punteggiatura, ripensamenti e tono in chat ed email", value: rewriteStatus, page: .ai)
            feature("Comandi sul testo", "wand.and.stars", .purple,
                    "«Traduci in inglese», «rendilo più formale»…", value: commandStatus, page: .ai)
        } header: {
            Text("Funzioni")
        } footer: {
            Text("L'audio non lascia mai il Mac. Con un servizio AI online viene inviato solo il testo, solo per riscrittura e comandi.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Riga stile Impostazioni di Sistema: icona, titolo, sottotitolo, stato a destra e chevron.
    private func feature(_ title: String, _ symbol: String, _ color: Color, _ subtitle: String,
                         value: (String, Color?), page: Navigation.Page) -> some View {
        Button { nav.page = page } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if let tint = value.1 { Circle().fill(tint).frame(width: 6, height: 6) }
                Text(value.0).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dictionarySummary: String {
        let d = DictionaryStore.shared.current
        return "\(d.terms.count) \(d.terms.count == 1 ? "termine" : "termini")"
    }

    private var rewriteStatus: (String, Color?) {
        let on = ["chat", "email", "plain"].contains { Profile(rawValue: $0)?.usesLLM(llmProfiles) ?? false }
        guard on else { return ("Spenta", nil) }
        switch ai.main {
        case .ok: return (LLMProvider.matching(llmBaseURL).name, .green)
        case .failed: return ("Da configurare", .orange)
        case .unknown, .checking: return ("…", nil)
        }
    }

    private var commandStatus: (String, Color?) {
        switch ai.command {
        case .ok:
            let own = !commandBaseURL.isEmpty
            return (LLMProvider.matching(own ? commandBaseURL : llmBaseURL).name, .green)
        case .failed: return ("Da configurare", .orange)
        case .unknown, .checking: return ("…", nil)
        }
    }

    // MARK: Oggi

    private var today: some View {
        let entries = controller.history.filter { $0.date.map(Calendar.current.isDateInToday) ?? false }
        let words = entries.reduce(0) { $0 + $1.final.split(whereSeparator: \.isWhitespace).count }
        let latency = entries.map(\.ms).sorted()
        return Section("Oggi") {
            LabeledContent("Dettature", value: "\(entries.count)")
            LabeledContent("Parole", value: "\(words)")
            if !latency.isEmpty { LabeledContent("Attesa tipica", value: secondsText(latency[latency.count / 2])) }
        }
    }
}
