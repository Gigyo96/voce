import AppKit
import AVFoundation
import SwiftUI

// MARK: - Panoramica: stato, cosa manca per partire, come si usa, cosa sa fare Voce

struct OverviewPage: View {
    @ObservedObject private var controller = Controller.shared
    @ObservedObject private var ai = AIStatus.shared
    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var meetings = MeetingStore.shared
    @AppStorage(Prefs.hotkey) private var hotkey
    @AppStorage(Prefs.handsFree) private var handsFree
    @AppStorage(Prefs.speechLanguage) private var speechLanguage   // i comandi vocali mostrati dipendono dalla lingua
    @AppStorage(Prefs.llmProfiles) private var llmProfiles
    @AppStorage(Prefs.llmBaseURL) private var llmBaseURL
    @AppStorage(Prefs.commandBaseURL) private var commandBaseURL
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
                Text(L("Voce")).font(.title2.weight(.semibold))
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
            permission(L("Microfono"), "mic.fill", .red, ok: mic, why: L("Per ascoltarti. L'audio resta sul Mac.")) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                Permissions.open("Privacy_Microphone")
            }
            permission(L("Accessibilità"), "accessibility", .blue, ok: ax, why: L("Per sentire il tasto e incollare il testo.")) {
                Hotkey.requestAccessibility()
                Permissions.open("Privacy_Accessibility")
            }
            permission(L("Monitoraggio input"), "keyboard.fill", .gray, ok: input, why: L("Per il tasto anche quando Voce è in secondo piano.")) {
                Hotkey.requestInputMonitoring()
                Permissions.open("Privacy_ListenEvent")
            }
            row(L("Modello vocale"), "waveform", .pink, subtitle: modelSubtitle) {
                switch controller.modelState {
                case .loading(let p): ProgressView(value: p).frame(width: 90)
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Button(L("Riprova")) { controller.loadModel() }
                }
            }
        } header: {
            Text(L("Prima di iniziare"))
        }
    }

    private var modelSubtitle: String {
        switch controller.modelState {
        case .loading: return L("Parakeet, ~700 MB solo la prima volta.")
        case .ready: return L("Pronto, funziona senza internet.")
        case .failed(let e): return e
        }
    }

    private func permission(_ title: String, _ symbol: String, _ color: Color, ok: Bool, why: String,
                            action: @escaping () -> Void) -> some View {
        row(title, symbol, color, subtitle: why) {
            if ok { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { Button(L("Concedi…"), action: action) }
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
            LabeledContent(L("Detta: tieni premuto, parla, rilascia")) { Keycaps([trigger.label]) }
            if let mode = Hotkey.HandsFree(rawValue: handsFree), mode != .off {
                LabeledContent(L("Mani libere (tocca il tasto per finire)")) { Keycaps(mode.keys(trigger)) }
            }
            LabeledContent(L("Trasforma il testo selezionato")) { Keycaps(trigger.commandKeys) }
            LabeledContent(L("Re-incolla l'ultima dettatura")) { Keycaps(["⌃", "⌥", "V"]) }
        } header: {
            HStack {
                Text(L("Come si usa"))
                Spacer()
                Button(L("Cambia scorciatoie…")) { nav.page = .shortcuts }.buttonStyle(.link).font(.caption)
            }
        } footer: {
            Text(L("Funziona in ogni app. Mentre detti puoi dire %@ e %@.", VoiceCommand.newline.spoken, VoiceCommand.paragraph.spoken))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Cosa sa fare Voce: ogni funzione con il suo stato, un clic porta dove si configura

    private var features: some View {
        Section {
            feature(L("Riunioni"), "person.2.wave.2.fill", .pink,
                    L("Registra o importa, distingue chi parla, risponde alle tue domande"), value: (meetingSummary, nil), page: .meetings)
            feature(L("Dizionario"), "character.book.closed.fill", .teal,
                    L("Nomi e termini tecnici scritti come vuoi tu"), value: (dictionarySummary, nil), page: .dictionary)
            feature(L("Riscrittura con AI"), "text.badge.checkmark", .blue,
                    L("Punteggiatura, ripensamenti e tono in chat ed email"), value: rewriteStatus, page: .ai)
            feature(L("Comandi sul testo"), "wand.and.stars", .purple,
                    L("«Traduci in inglese», «rendilo più formale»…"), value: commandStatus, page: .ai)
        } header: {
            Text(L("Funzioni"))
        } footer: {
            Text(L("L'audio non lascia mai il Mac. Con un servizio AI online viene inviato solo il testo, solo per riscrittura, comandi e riunioni."))
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
        return d.terms.count == 1 ? L("1 termine") : L("%ld termini", d.terms.count)
    }

    private var meetingSummary: String {
        let count = meetings.meetings.count
        return count == 1 ? L("1 riunione") : L("%ld riunioni", count)
    }

    private var rewriteStatus: (String, Color?) {
        let on = ["chat", "email", "plain"].contains { Profile(rawValue: $0)?.usesLLM(llmProfiles) ?? false }
        guard on else { return (L("Spenta"), nil) }
        switch ai.main {
        case .ok: return (LLMProvider.matching(llmBaseURL).name, .green)
        case .failed: return (L("Da configurare"), .orange)
        case .unknown, .checking: return ("…", nil)
        }
    }

    private var commandStatus: (String, Color?) {
        switch ai.command {
        case .ok:
            let own = !commandBaseURL.isEmpty
            return (LLMProvider.matching(own ? commandBaseURL : llmBaseURL).name, .green)
        case .failed: return (L("Da configurare"), .orange)
        case .unknown, .checking: return ("…", nil)
        }
    }

    // MARK: Oggi

    private var today: some View {
        let entries = controller.history.filter { $0.date.map(Calendar.current.isDateInToday) ?? false }
        let words = entries.reduce(0) { $0 + $1.final.split(whereSeparator: \.isWhitespace).count }
        let latency = entries.map(\.ms).sorted()
        return Section(L("Oggi")) {
            LabeledContent(L("Dettature"), value: "\(entries.count)")
            LabeledContent(L("Parole"), value: "\(words)")
            if !latency.isEmpty { LabeledContent(L("Attesa tipica"), value: secondsText(latency[latency.count / 2])) }
        }
    }
}
