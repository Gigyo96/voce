import AppKit
import SwiftUI

// MARK: - Componenti SwiftUI condivisi dalle pagine, dal HUD e dalla finestra

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

struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .foregroundStyle(selected ? Color.white : Color.primary)
    }
}

/// Disposizione a capo automatico (le parole della QuickFix).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Proposte nil/infinite (dimensione ideale) o zero (minima): mai restituire una dimensione infinita.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 600
        let rows = arrange(width: width, subviews: subviews)
        return CGSize(width: min(width, rows.map(\.width).max() ?? 0), height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

@MainActor func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s)) ?? AttributedString(s)
}

func secondsText(_ ms: Int) -> String {
    (Double(ms) / 1000).formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "it_IT"))) + " s"
}
