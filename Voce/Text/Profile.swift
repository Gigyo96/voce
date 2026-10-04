import Foundation

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

    var isAgent: Bool { self == .agentIDE || self == .agentTerminal }

    /// `llmProfiles` è una lista separata da virgole, modificabile da Impostazioni (default "chat,email").
    func usesLLM(_ llmProfiles: String) -> Bool {
        llmProfiles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(rawValue)
    }

    /// Il prompt dello stile per questo profilo (personalizzabile nella pagina Prompt).
    var stylePrompt: PromptID {
        switch self {
        case .chat: return .styleChat
        case .email: return .styleEmail
        default: return .stylePlain
        }
    }

    func llmInstructions(_ store: PromptStore = .shared) -> String { store.text(stylePrompt) }
}
