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
