import AppKit
import SwiftUI

// MARK: - Finestra principale: sidebar stile Impostazioni di Sistema, una pagina per voce (Voce/Pages)

@MainActor final class Navigation: ObservableObject {
    static let shared = Navigation()

    /// Aggiungere una pagina: un caso qui (titolo, icona, colore, gruppo) e la sua vista in `PageView`.
    enum Page: String, CaseIterable, Identifiable {
        case overview, history, dictionary, shortcuts, ai, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Panoramica"
            case .history: return "Cronologia"
            case .dictionary: return "Dizionario"
            case .shortcuts: return "Scorciatoie"
            case .ai: return "Funzioni AI"
            case .general: return "Generale"
            }
        }
        var symbol: String {
            switch self {
            case .overview: return "waveform"
            case .history: return "clock.fill"
            case .dictionary: return "character.book.closed.fill"
            case .shortcuts: return "command"
            case .ai: return "sparkles"
            case .general: return "gearshape.fill"
            }
        }
        var tint: Color {
            switch self {
            case .overview: return Brand.magenta
            case .history: return .orange
            case .dictionary: return .teal
            case .shortcuts: return .indigo
            case .ai: return .purple
            case .general: return .gray
            }
        }
        /// Sidebar in due gruppi: cosa usi ogni giorno, poi le impostazioni.
        static let groups: [[Page]] = [[.overview, .history, .dictionary], [.shortcuts, .ai, .general]]
    }

    @Published var page: Page? = .overview
    @Published var dictionaryTab: DictionaryTab = .terms
    /// Dettatura da cui creare una correzione (dalla Cronologia); `nil` = l'ultima.
    @Published var correctionSource: Log.Entry?
}

@MainActor enum Windows {
    private static var main: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(_ page: Navigation.Page = .overview) {
        Navigation.shared.page = page
        if main == nil {
            let host = NSHostingController(rootView: MainView())
            // La dimensione la decide la finestra, non il contenuto: con i testi che vanno a capo SwiftUI e Auto Layout
            // possono rincorrersi (altezza minima ↔ larghezza) fino a bloccare l'interfaccia.
            host.sizingOptions = []
            let w = KeyWindow(contentViewController: host)
            w.title = "Voce"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 860, height: 600))
            w.contentMinSize = NSSize(width: 720, height: 480)
            w.setFrameAutosaveName("VoceMain")
            if w.frame.origin == .zero { w.center() }
            main = w
            // Finché la finestra è aperta Voce compare nel Dock e in ⌘Tab; chiusa, torna solo nella barra dei menu.
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        main?.makeKeyAndOrderFront(nil)
    }
}

/// ⌘W e ⌘, funzionano anche se l'app (LSUIElement) non ha un menu File/Voce completo.
private final class KeyWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "w": performClose(nil); return true
            case ",": Navigation.shared.page = .general; return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct MainView: View {
    @ObservedObject private var nav = Navigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.page) {
                ForEach(Navigation.Page.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { page in
                            Label { Text(page.title) } icon: { IconTile(symbol: page.symbol, color: page.tint, size: 20) }
                                .tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(12) }
        } detail: {
            let page = nav.page ?? .overview
            PageView(page: page).navigationTitle(page.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// L'unico punto che collega una pagina alla sua vista (usato anche da `Voce snapshot`).
struct PageView: View {
    let page: Navigation.Page

    var body: some View {
        switch page {
        case .overview: OverviewPage()
        case .history: HistoryPage()
        case .dictionary: DictionaryPage()
        case .shortcuts: ShortcutsPage()
        case .ai: AIPage()
        case .general: GeneralPage()
        }
    }
}

/// Stato sempre visibile in fondo alla sidebar.
private struct SidebarStatus: View {
    @ObservedObject private var controller = Controller.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(controller.status.tint).frame(width: 8, height: 8)
            Text(controller.status.short).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Componenti comuni

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).lineLimit(3)
            Spacer(minLength: 8)
            actions
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

/// Nome e icona di un'app dal bundle ID (per la Cronologia).
@MainActor enum AppInfo {
    private static var cache: [String: (String, NSImage?)] = [:]

    static func lookup(_ bundleID: String) -> (name: String, icon: NSImage?) {
        if let hit = cache[bundleID] { return hit }
        var out: (String, NSImage?) = (bundleID, nil)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            out = (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        cache[bundleID] = out
        return out
    }
}
