import AppKit
import SwiftUI

/// `Voce snapshot <cartella>`: renderizza le pagine della finestra e gli stati del HUD in PNG, senza permessi
/// di registrazione schermo. Serve per rivedere la UI dopo una modifica.
@MainActor enum Snapshot {
    static func run(_ args: [String]) {
        let dir = URL(fileURLWithPath: args.first ?? "snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // Solo il dettaglio di ogni pagina (NavigationSplitView offscreen esce vuota). Finestra senza bordo e
        // `sizingOptions = []` come nell'app: così anche i Form e le List vengono disegnati.
        let bg = Color(nsColor: .windowBackgroundColor)
        for page in Navigation.Page.allCases {
            render(PageView(page: page).background(bg), size: NSSize(width: 680, height: 900), to: dir.appending(path: "page-\(page.rawValue).png"))
        }
        renderMeetings(bg: bg, to: dir)
        Navigation.shared.dictionaryTab = .corrections
        render(PageView(page: .dictionary).background(bg), size: NSSize(width: 680, height: 600), to: dir.appending(path: "page-dictionary-corrections.png"))

        let model = HUDModel()
        model.beginListening()
        for i in 0..<HUDModel.barCount { model.push(Float(0.002 + 0.05 * abs(sin(Double(i) / 2.3)) * Double(i) / Double(HUDModel.barCount))) }
        let states: [(String, HUD.State)] = [
            ("listening", .listening(.pushToTalk)), ("handsfree", .listening(.handsFree)), ("command", .listening(.command)),
            ("processing", .processing), ("done", .done("Aggiungi un useEffect che carica i dati da Supabase")),
            ("notice", .notice("Non ho sentito nulla", symbol: "mic.slash")), ("error", .error("Nessun testo selezionato")),
        ]
        for (name, state) in states {
            model.state = state
            // Solo la capsula: il pannello vero è più alto (spazio per il testo dal vivo), qui si ritaglia il vuoto sopra.
            render(HUDView(model: model).background(Color(white: 0.85)), size: NSSize(width: HUD.size.width, height: 90),
                   to: dir.appending(path: "hud-\(name).png"))
        }
        // Testo dal vivo: mentre parli e mentre arriva il testo definitivo.
        model.liveText = L("Allora, nel componente della dashboard aggiungi un useEffect che carica i progetti da Supabase e mostra uno spinner")
        for (name, state) in [("live", HUD.State.listening(.pushToTalk)), ("live-processing", .processing)] {
            model.state = state
            render(HUDView(model: model).background(Color(white: 0.85)), size: NSSize(width: HUD.size.width, height: 160),
                   to: dir.appending(path: "hud-\(name).png"))
        }
        for state in [Brand.MenuState.ready, .loading, .recording, .processing, .attention] {
            let img = Brand.menuIcon(state)
            let view = Image(nsImage: img).resizable().frame(width: 80, height: 64).padding(8).background(Color.white)
            render(view, size: NSSize(width: 96, height: 80), to: dir.appending(path: "menu-\(state).png"))
        }
        // Anteprima social di GitHub/LinkedIn: 1280×640, sotto 1 MB.
        model.state = .listening(.pushToTalk)
        render(Banner(hud: HUDView(model: model)), size: NSSize(width: 1280, height: 640), to: dir.appending(path: "social.png"))
        print("✓ \(dir.path)")
    }

    /// Una riunione di esempio, solo in memoria: elenco, dettaglio nelle tre schede, registrazione e audio durante la dettatura.
    private static func renderMeetings(bg: Color, to dir: URL) {
        var m = Meeting(id: "demo", title: "Lancio del nuovo prodotto", createdAt: Date(), source: .recorded, state: .ready, duration: 1_873)
        m.speakers = [.init(id: "me", name: "Luigi"), .init(id: "s1", name: "Marco"), .init(id: "s2", name: "Luca")]
        m.utterances = [
            .init(id: 0, speaker: "s1", start: 3, end: 11, text: "Buongiorno a tutti, oggi parliamo del lancio del nuovo prodotto e del budget per il prossimo trimestre."),
            .init(id: 1, speaker: "me", start: 12, end: 16, text: "Ciao Marco. Ho sentito Luca: propone il quindici novembre."),
            .init(id: 2, speaker: "s2", start: 17, end: 25, text: "Sì, il quindici novembre mi sembra una buona data. Me ne occupo io del piano di comunicazione, lo consegno entro venerdì."),
            .init(id: 3, speaker: "s1", start: 26, end: 33, text: "Perfetto. Servono ventimila euro di budget: li approviamo oggi?"),
        ]
        m.summary = """
            ## Sintesi
            Il team ha fissato il lancio al **15 novembre** e ha approvato il budget per la comunicazione.

            ## Decisioni
            - Lancio il 15 novembre
            - Budget di 20.000 € approvato

            ## Azioni da fare
            - [ ] Luca: piano di comunicazione (entro venerdì)
            - [ ] Marco: confermare il budget con l'amministrazione
            """
        m.chat = [.init(role: .user, text: "Chi consegna il piano di comunicazione e quando?"),
                  .init(role: .assistant, text: "**Luca** consegna il piano di comunicazione **entro venerdì** [00:17]. Ha anche chiesto un budget di 20.000 €.")]
        var processing = Meeting(id: "demo2", title: "registrazione-cliente.m4a", createdAt: Date().addingTimeInterval(-86_400), source: .imported, state: .processing)
        processing.duration = 0
        AIStatus.shared.freeze(.ok)
        MeetingStore.shared.insertForPreview(processing)
        MeetingStore.shared.insertForPreview(m)
        render(MeetingsPage().background(bg), size: NSSize(width: 680, height: 420), to: dir.appending(path: "page-meetings-list.png"))
        Navigation.shared.meetingID = "demo"
        render(MeetingDetailView(id: "demo").background(bg), size: NSSize(width: 680, height: 640), to: dir.appending(path: "meeting-transcript.png"))
        render(SummaryTab(id: "demo").background(bg), size: NSSize(width: 680, height: 420), to: dir.appending(path: "meeting-summary.png"))
        render(ChatTab(id: "demo").background(bg), size: NSSize(width: 680, height: 260), to: dir.appending(path: "meeting-chat.png"))
        Navigation.shared.meetingID = nil
        MeetingRecorder.shared.previewState(seconds: 754, mic: "MacBook Pro Microphone", output: "MacBook Pro Speakers")
        render(RecordingView().background(bg), size: NSSize(width: 680, height: 760), to: dir.appending(path: "meeting-recording.png"))
        let saved = (Prefs.mediaMode.value, Prefs.mediaLevel.value)
        Prefs.mediaMode.value = MediaMode.lower.rawValue
        Prefs.mediaLevel.value = 20
        render(GeneralPage().background(bg), size: NSSize(width: 680, height: 1000), to: dir.appending(path: "page-general-lower.png"))
        (Prefs.mediaMode.value, Prefs.mediaLevel.value) = saved
    }

    /// Icona, nome, promessa e un HUD vero: la prima cosa che si vede su GitHub e nei post.
    private struct Banner: View {
        let hud: HUDView
        var body: some View {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.07)
                // Gradienti radiali, non blur: `cacheDisplay` non disegna i filtri.
                RadialGradient(colors: [Brand.coral.opacity(0.45), .clear], center: UnitPoint(x: 0.12, y: 0.0), startRadius: 0, endRadius: 620)
                RadialGradient(colors: [Brand.violet.opacity(0.55), .clear], center: UnitPoint(x: 0.92, y: 1.0), startRadius: 0, endRadius: 680)
                VStack(spacing: 28) {
                    HStack(spacing: 28) {
                        if let icon = NSImage(contentsOfFile: "Voce/Resources/AppIcon.icns") {
                            Image(nsImage: icon).resizable().frame(width: 150, height: 150)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Voce").font(.system(size: 96, weight: .bold, design: .rounded))
                            Text("Tieni premuto, parla, rilascia.").font(.system(size: 36, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    hud.frame(width: HUD.size.width, height: 160).scaleEffect(1.2)
                    Text("Dettatura vocale locale per macOS  ·  Parakeet sul Neural Engine  ·  Niente lascia il tuo Mac")
                        .font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white)
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        // Senza bordo: una finestra con titolo viene ridotta all'altezza dello schermo e le pagine lunghe si comprimono.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []   // come la finestra vera: la dimensione la decide la finestra, i testi vanno a capo
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
