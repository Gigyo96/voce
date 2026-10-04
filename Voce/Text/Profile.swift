import AppKit

// MARK: - Profilo (§3.3)

/// Come trattare il testo a seconda dell'app in primo piano: agent (IDE e terminali) ricevono testo letterale,
/// chat ed email possono passare dall'LLM.
enum Profile: String, CaseIterable, Sendable {
    case agentIDE, agentTerminal, chat, email, plain

    static func from(bundleID: String?) -> Profile {
        switch bundleID {
        case "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
             "com.exafunction.windsurf", "dev.zed.Zed":                                       return .agentIDE
        case "com.apple.Terminal", "com.googlecode.iterm2",
             "com.mitchellh.ghostty", "dev.warp.Warp-Stable":                                 return .agentTerminal
        case "com.tinyspeck.slackmacgap", "com.hnc.Discord",
             "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp":                                return .chat
        case "com.apple.mail", "com.microsoft.Outlook":                                       return .email
        default:                                                                              return .plain
        }
    }

    @MainActor static var current: Profile { from(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }

    var isAgent: Bool { self == .agentIDE || self == .agentTerminal }

    /// `llmProfiles` è una lista separata da virgole, modificabile da Impostazioni (default "chat,email").
    func usesLLM(_ llmProfiles: String) -> Bool {
        llmProfiles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(rawValue)
    }

    var newlineKey: String { self == .agentTerminal ? "shift+return" : "return" }

    var llmInstructions: String {
        switch self {
        case .chat:  return "Messaggio di chat informale. Frasi brevi, tono colloquiale. Non aggiungere saluti, firme o emoji."
        case .email: return "Email. Punteggiatura curata, paragrafi separati da una riga vuota. Non aggiungere saluti, firme o oggetto non dettati."
        default:     return "Testo generico. Correggi solo punteggiatura, maiuscole ed esitazioni."
        }
    }
}
