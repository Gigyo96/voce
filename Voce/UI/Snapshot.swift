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
            render(HUDView(model: model).background(Color(white: 0.85)), size: NSSize(width: 620, height: 90),
                   to: dir.appending(path: "hud-\(name).png"))
        }
        for state in [Brand.MenuState.ready, .loading, .recording, .processing, .attention] {
            let img = Brand.menuIcon(state)
            let view = Image(nsImage: img).resizable().frame(width: 80, height: 64).padding(8).background(Color.white)
            render(view, size: NSSize(width: 96, height: 80), to: dir.appending(path: "menu-\(state).png"))
        }
        // Anteprima social di GitHub/LinkedIn: 1280×640, sotto 1 MB.
        model.state = .done("Aggiungi un useEffect che carica i dati da Supabase")
        render(Banner(hud: HUDView(model: model)), size: NSSize(width: 1280, height: 640), to: dir.appending(path: "social.png"))
        print("✓ \(dir.path)")
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
                        if let icon = NSImage(contentsOfFile: "Voce/AppIcon.icns") {
                            Image(nsImage: icon).resizable().frame(width: 150, height: 150)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Voce").font(.system(size: 96, weight: .bold, design: .rounded))
                            Text("Tieni premuto, parla, rilascia.").font(.system(size: 36, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    hud.frame(width: 620, height: 90).scaleEffect(1.3)
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
