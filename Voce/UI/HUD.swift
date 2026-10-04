import AppKit
import SwiftUI

// MARK: - HUD (§8): NSPanel non attivante in basso al centro, con waveform e testo dal vivo durante l'ascolto

@MainActor final class HUD {
    enum State: Equatable {
        case listening(Hotkey.Mode)
        case processing
        case done(String)                       // anteprima del testo inserito
        case notice(String, symbol: String)     // informativo: nessuna voce, annullata…
        case error(String)
    }

    /// Spazio per il riquadro del testo dal vivo sopra la capsula; la parte vuota è trasparente e non riceve clic.
    static let size = NSSize(width: 640, height: 230)

    /// Livello del microfono (RMS 0…1) letto ~30 volte al secondo mentre si ascolta.
    var levelSource: () -> Float = { 0 }

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var meter: Timer?

    /// `delay`: per l'ascolto si aspetta un attimo, così ⌘ destro usato come modificatore (⌘C, ⌘Tab…)
    /// o un tap singolo non fanno lampeggiare il HUD. La registrazione parte comunque subito.
    func show(_ state: State, delay: Double = 0) {
        hideTask?.cancel()
        showTask?.cancel()
        guard delay > 0 else { present(state); return }
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.present(state)
        }
    }

    /// Testo trascritto finora (anteprima dal vivo). Resta visibile anche durante la trascrizione finale.
    func setLiveText(_ text: String) {
        model.liveText = text
    }

    func hide(after seconds: Double = 0) {
        showTask?.cancel()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self else { return }
            self.stopMeter()
            self.panel?.orderOut(nil)
            self.model.liveText = ""
        }
    }

    private func present(_ state: State) {
        let p = panel ?? makePanel()
        let wasVisible = p.isVisible
        switch state {
        case .listening:
            if case .listening = model.state, wasVisible {} else { model.beginListening() }
            startMeter()
        case .processing:
            stopMeter()
        default:
            stopMeter()
            model.liveText = ""
        }
        model.state = state
        if !wasVisible {
            position(p)   // solo all'apparizione: non insegue il puntatore durante la dettatura
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        }
        switch state {
        case .done: hide(after: 1.4)
        case .notice: hide(after: 1.8)
        case .error: hide(after: 3.2)
        default: break
        }
    }

    private func startMeter() {
        guard meter == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.push(self.levelSource())
            }
        }
        RunLoop.main.add(t, forMode: .common)
        meter = t
    }

    private func stopMeter() {
        meter?.invalidate()
        meter = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        panel = p
        return p
    }

    /// In basso al centro dello schermo con il puntatore, sopra il Dock.
    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: frame.midX - p.frame.width / 2, y: frame.minY + 12))
    }
}

@MainActor final class HUDModel: ObservableObject {
    static let barCount = 44
    static let rate = 30.0   // campioni di livello al secondo

    @Published var state: HUD.State = .processing
    @Published var liveText = ""
    @Published private(set) var levels = [CGFloat](repeating: 0, count: barCount)
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var quiet = false
    /// Livello attuale, smorzato (attacco rapido, rilascio lento): fa pulsare l'anello attorno al pallino.
    @Published private(set) var level: CGFloat = 0
    /// Istante dell'ultimo campione: la waveform scorre in modo continuo tra un campione e l'altro.
    private(set) var lastPush = Date()

    private var startedAt = Date()
    private var loudest: Float = 0

    func beginListening() {
        startedAt = Date()
        elapsed = 0
        loudest = 0
        quiet = false
        level = 0
        liveText = ""
        levels = [CGFloat](repeating: 0, count: Self.barCount)
    }

    /// Nuovo campione di livello: scala logaritmica −55…−15 dBFS → 0…1, la waveform scorre verso sinistra.
    func push(_ rms: Float) {
        loudest = max(loudest, rms)
        let db = 20 * log10(max(rms, 1e-7))
        let n = CGFloat(min(1, max(0, (db + 55) / 40)))
        let smoothed = max(n, (levels.last ?? 0) * 0.45)
        levels.removeFirst()
        levels.append(smoothed)
        level = n > level ? n : level * 0.82 + n * 0.18
        lastPush = Date()
        elapsed = Date().timeIntervalSince(startedAt)
        // Dopo 2,5 s di quasi silenzio: probabilmente microfono sbagliato o muto.
        let isQuiet = elapsed > 2.5 && loudest < 0.006
        if isQuiet != quiet { quiet = isQuiet }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if showsLiveText {
                LiveTextCard(text: model.liveText, final: model.state == .processing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            capsule
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 14)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: showsLiveText)
        .environment(\.colorScheme, .dark)
    }

    private var showsLiveText: Bool {
        guard !model.liveText.isEmpty else { return false }
        switch model.state {
        case .listening, .processing: return true
        default: return false
        }
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            badge
            content
        }
        .padding(.leading, 7)
        .padding(.trailing, 16)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        .animation(.spring(duration: 0.32, bounce: 0.2), value: kind)
        .accessibilityElement(children: .combine)
    }

    /// Cambia solo al cambio di stato "logico", così la molla non scatta a ogni campione della waveform.
    private var kind: String {
        switch model.state {
        case .listening(let m): return "listening-\(m)-\(model.quiet)"
        case .processing: return "processing"
        case .done(let t): return "done-\(t)"
        case .notice(let t, _): return "notice-\(t)"
        case .error(let t): return "error-\(t)"
        }
    }

    @ViewBuilder private var badge: some View {
        let (symbol, fill): (String?, AnyShapeStyle) = {
            switch model.state {
            case .listening(.pushToTalk): return ("mic.fill", AnyShapeStyle(Color.red))
            case .listening(.handsFree): return ("lock.fill", AnyShapeStyle(Color.red))
            case .listening(.command): return ("wand.and.stars", AnyShapeStyle(Brand.commandGradient))
            case .processing: return (nil, AnyShapeStyle(Color.white.opacity(0.12)))
            case .done: return ("checkmark", AnyShapeStyle(Color.green))
            case .notice(_, let s): return (s, AnyShapeStyle(Color.white.opacity(0.18)))
            case .error: return ("exclamationmark", AnyShapeStyle(Color.orange))
            }
        }()
        ZStack {
            if case .listening(let mode) = model.state {
                // Anello che respira con la voce.
                Circle()
                    .fill(mode == .command ? Brand.commandColors[0].opacity(0.35) : Color.red.opacity(0.35))
                    .scaleEffect(1 + model.level * 0.55)
                    .opacity(0.3 + model.level * 0.7)
                    .animation(.easeOut(duration: 0.12), value: model.level)
            }
            Circle().fill(fill)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                ThinkingBars().frame(width: 16, height: 14)
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .listening(let mode):
            if mode == .command { label(L("Comando")).foregroundStyle(.white) }
            Waveform(model: model, colors: mode == .command ? Brand.commandColors : Brand.colors)
                .frame(width: 170, height: 28)
            Text(Self.clock(model.elapsed))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            if model.quiet {
                label(L("Non ti sento: controlla il microfono")).foregroundStyle(.orange)
            } else if mode == .handsFree {
                label(L("tap per finire · esc annulla")).foregroundStyle(.white.opacity(0.55))
            }
        case .processing:
            label(L("Trascrivo…")).foregroundStyle(.white.opacity(0.85))
        case .done(let text):
            Text(Self.preview(text)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
        case .notice(let text, _):
            label(text).foregroundStyle(.white.opacity(0.85))
        case .error(let text):
            label(Self.preview(text)).foregroundStyle(.white.opacity(0.92))
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium)).lineLimit(1)
    }

    /// Una riga, al massimo ~56 caratteri: la capsula resta compatta e si adatta al testo.
    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > 56 ? flat.prefix(55).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// Il testo che stai dicendo, sopra la capsula: le ultime righe, con un cursore che lampeggia mentre parli.
/// `final`: tasto rilasciato, si attende il testo definitivo (resta visibile ma attenuato).
struct LiveTextCard: View {
    let text: String
    let final: Bool

    var body: some View {
        let shown = LivePreview.tail(text)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let caretOn = !final && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            (Text(shown) + Text(" ▍").foregroundStyle(Brand.magenta.opacity(caretOn ? 1 : 0)))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(final ? 0.55 : 0.95))
                .lineSpacing(3)
                .lineLimit(3)
                .frame(width: 520, alignment: .leading)
                .animation(.easeOut(duration: 0.18), value: shown)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(alignment: .top) {
            // Sottile filo di colore del brand in alto: si capisce subito che è Voce che ascolta.
            LinearGradient(colors: Brand.colors, startPoint: .leading, endPoint: .trailing)
                .frame(height: 1.5).padding(.horizontal, 24).opacity(final ? 0.3 : 0.8)
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
        .accessibilityLabel(text)
    }
}

/// Le cinque barre del logo che ondeggiano in sequenza: "sto elaborando".
struct ThinkingBars: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.6) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(LinearGradient(colors: Brand.colors, startPoint: .top, endPoint: .bottom))
                        .frame(width: 2, height: 4 + 10 * (0.5 + 0.5 * sin(t * 7 - Double(i) * 0.9)))
                }
            }
        }
    }
}

/// Barre arrotondate e simmetriche che scorrono da destra a sinistra in modo continuo (60 fps, interpolando tra i
/// campioni a 30 Hz), con un alone del colore del brand. Nel silenzio respirano appena, così non sembrano spente.
struct Waveform: View {
    @ObservedObject var model: HUDModel
    let colors: [Color]

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let levels = model.levels
                let n = levels.count
                guard n > 1 else { return }
                let barW: CGFloat = 2.4
                let step = (size.width - barW) / CGFloat(n - 2)
                // Frazione di passo trascorsa dall'ultimo campione: le barre scivolano invece di saltare.
                let phase = min(1, context.date.timeIntervalSince(model.lastPush) * HUDModel.rate)
                let t = context.date.timeIntervalSinceReferenceDate
                var path = Path()
                for (i, level) in levels.enumerated() {
                    let x = (CGFloat(i) - CGFloat(phase)) * step
                    guard x > -barW, x < size.width else { continue }
                    let breathing = 1.5 * (0.5 + 0.5 * sin(t * 2.6 + Double(i) * 0.45))
                    let h = max(3 + breathing, level * size.height)
                    path.addRoundedRect(in: CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h),
                                        cornerSize: CGSize(width: barW / 2, height: barW / 2))
                }
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                // Alone: lo stesso disegno sfocato sotto quello nitido.
                ctx.drawLayer { glow in
                    glow.addFilter(.blur(radius: 5))
                    glow.opacity = 0.55
                    glow.fill(path, with: shading)
                }
                ctx.fill(path, with: shading)
            }
        }
        .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: UnitPoint(x: 0.3, y: 0.5)))
    }
}
