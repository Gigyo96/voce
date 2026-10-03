import AppKit
import SwiftUI

/// Identità visiva condivisa: icona di menu bar, colori, piccoli componenti riusati da HUD e finestra.
/// L'icona dell'app (tools/make-icon.swift) usa la stessa forma a cinque barre.
enum Brand {
    static let barHeights: [CGFloat] = [0.38, 0.72, 1.0, 0.58, 0.30]

    static let coral = Color(red: 1.00, green: 0.45, blue: 0.36)
    static let magenta = Color(red: 0.93, green: 0.27, blue: 0.55)
    static let violet = Color(red: 0.42, green: 0.25, blue: 0.96)
    static let colors = [coral, magenta, violet]
    static let commandColors = [Color(red: 0.55, green: 0.40, blue: 1.0), Color(red: 0.25, green: 0.60, blue: 1.0)]
    static let commandGradient = LinearGradient(colors: commandColors, startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Stato mostrato dall'icona nella barra dei menu.
    enum MenuState: Equatable { case ready, loading, recording, processing, attention }

    @MainActor private static var cache: [MenuState: NSImage] = [:]

    /// Cinque barre da 18 pt. Template (si adatta a barra chiara/scura) tranne in registrazione, dove è rossa.
    @MainActor static func menuIcon(_ state: MenuState) -> NSImage {
        if let img = cache[state] { return img }
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let barW: CGFloat = 2.2, gap: CGFloat = 1.6
            let heights: [CGFloat] = state == .loading ? [0.25, 0.25, 0.25, 0.25, 0.25]
                : state == .processing ? [0.5, 0.5, 0.5, 0.5, 0.5] : barHeights
            let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
            var x = (rect.width - total) / 2 - (state == .attention ? 2 : 0)
            let color: NSColor = state == .recording ? .systemRed : .black
            color.withAlphaComponent(state == .loading ? 0.55 : 1).setFill()
            for h in heights {
                let bh = max(barW, (rect.height - 2) * h)
                NSBezierPath(roundedRect: NSRect(x: x, y: (rect.height - bh) / 2, width: barW, height: bh),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            if state == .attention {
                // Pallino in alto a destra: "c'è qualcosa da sistemare".
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - 5.5, y: rect.height - 6, width: 5, height: 5)).fill()
            }
            return true
        }
        img.isTemplate = state != .recording
        img.accessibilityDescription = "Voce"
        cache[state] = img
        return img
    }
}

/// Tasto disegnato come un keycap: rende leggibili le scorciatoie ("⌘ destro", "Esc"…).
struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

/// Una scorciatoia: keycap separati da "+" (o da uno spazio se il tasto si ripete, come nel doppio tap).
struct Keycaps: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                if i > 0, keys[i - 1] != k { Text("+").font(.caption).foregroundStyle(.tertiary) }
                Keycap(k)
            }
        }
    }
}

/// Icona su riquadro colorato, come nella barra laterale delle Impostazioni di Sistema.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

/// Logo dell'app in SwiftUI (barre bianche su squircle con gradiente), per intestazioni e onboarding.
struct AppLogo: View {
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: Brand.colors,
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                HStack(spacing: size * 0.062) {
                    ForEach(Array(Brand.barHeights.enumerated()), id: \.offset) { _, h in
                        Capsule().fill(.white).frame(width: size * 0.085, height: max(size * 0.085, size * 0.5 * h))
                    }
                }
            }
            .frame(width: size, height: size)
            .shadow(color: Brand.magenta.opacity(0.3), radius: size * 0.08, y: size * 0.04)
    }
}
