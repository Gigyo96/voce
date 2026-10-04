import SwiftUI

/// Markdown dei riepiloghi e delle risposte dell'AI: titoli, elenchi (anche «- [ ]» delle azioni), paragrafi e il
/// formato dentro le righe (grassetto, corsivo, codice, link). `Text` da solo non disegna i blocchi.
struct MarkdownText: View {
    let text: String

    enum Block: Equatable {
        case heading(Int, String)
        case bullet(indent: Int, marker: String, text: String)
        case paragraph(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(markdown(t)).font(level <= 1 ? .title3.bold() : .headline).padding(.top, level <= 1 ? 0 : 6)
                case .bullet(let indent, let marker, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                        Text(markdown(t)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .paragraph(let t):
                    Text(markdown(t)).fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    nonisolated static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = (line.prefix { $0 == " " }.count) / 2
            if trimmed.isEmpty { flush(); continue }
            if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flush()
                out.append(.heading(heading.output.1.count, String(heading.output.2)))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                out.append(.rule)
            } else if let task = trimmed.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.+)$/) {
                flush()
                out.append(.bullet(indent: indent, marker: task.output.1 == " " ? "☐" : "☑", text: String(task.output.2)))
            } else if let item = trimmed.firstMatch(of: /^[-*+•]\s+(.+)$/) {
                flush()
                out.append(.bullet(indent: indent, marker: "•", text: String(item.output.1)))
            } else if let item = trimmed.firstMatch(of: /^(\d+)[.)]\s+(.+)$/) {
                flush()
                out.append(.bullet(indent: indent, marker: "\(item.output.1).", text: String(item.output.2)))
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return out
    }
}
