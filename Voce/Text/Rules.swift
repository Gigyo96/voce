import Foundation

// MARK: - Livello 1: regole deterministiche (§6.1)

struct RulesOutput: Equatable {
    var text: String
    var send: Bool
}

enum Rules {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // Solo filler non ambigui, in italiano e in inglese ("ehm", "uhm", "eh", "hmm", "erm"); "cioè", "tipo", "like"
    // si aggiungono solo se i dati lo giustificano.
    private static let filler = regex(#"(?<![\p{L}\p{N}])(?:e+h*m+|e+h+|(?<!\d )m+|u+h*m+|u+h+|h+m+|e+r+m+)(?![\p{L}\p{N}]),?\s*"#)

    /// Comandi vocali di una lingua: vanno a capo, lasciano una riga vuota, premono Invio.
    private struct Commands {
        let newline: NSRegularExpression
        let paragraph: NSRegularExpression
        let send: NSRegularExpression
    }

    private static let italian = Commands(
        // "a capo" ma non "a capo del/della/di…" (uso normale nel parlato).
        newline: regex(#"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}])a capo(?![\p{L}\p{N}])(?!\s+(?:del|della|dello|dei|degli|delle|di)\b)[.,;:!?]?[ \t]*"#),
        paragraph: regex(#"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}])nuovo paragrafo(?![\p{L}\p{N}])[.,;:!?]?[ \t]*"#),
        send: regex(#"[\s,;:.]*(?<![\p{L}\p{N}])invia(?![\p{L}\p{N}])[.!]?\s*$"#))

    // "new line" ma non quando descrive qualcosa: "add a new line", "the new line character", "a new line of code".
    private static let notDescribed = #"(?<!\b(?:a|an|the|one|another|each|every|this|that|add|insert)\s)"#
    private static let notFollowedByObject = #"(?!\s+(?:character|characters|char|chars|symbol|symbols|of|in|at|after|before|between|to|is|are|was|were)\b)"#

    private static let english = Commands(
        newline: regex(#"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}])"# + notDescribed + #"new[ \t-]?line(?![\p{L}\p{N}])"# + notFollowedByObject + #"[.,;:!?]?[ \t]*"#),
        paragraph: regex(#"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}])"# + notDescribed + #"new paragraph(?![\p{L}\p{N}])"# + notFollowedByObject + #"[.,;:!?]?[ \t]*"#),
        send: regex(#"[\s,;:.]*(?<![\p{L}\p{N}])send(?![\p{L}\p{N}])[.!]?\s*$"#))

    static func apply(_ input: String, profile: Profile, sendOnInvia: Bool, language: SpeechLanguage = .auto) -> RulesOutput {
        var commands: [Commands] = []
        if language.usesItalianCommands { commands.append(italian) }
        if language.usesEnglishCommands { commands.append(english) }

        var s = input
        var shouldSend = false
        if sendOnInvia, profile.isAgent, let c = commands.first(where: { matches($0.send, s) }) {
            s = replace(c.send, in: s, with: "")
            shouldSend = true
        }
        s = replace(filler, in: s, with: "")
        for c in commands { s = replace(c.paragraph, in: s, with: "\n\n") }
        for c in commands { s = replace(c.newline, in: s, with: "\n") }
        return RulesOutput(text: tidy(s), send: shouldSend)
    }

    /// Spazi doppi, spazi prima della punteggiatura, punteggiatura orfana a inizio riga, maiuscola a inizio riga.
    static func tidy(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,;:])\1+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*[,.;:]+[ \t]*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizeLineStarts(s)
    }

    private static func capitalizeLineStarts(_ s: String) -> String {
        var out = ""
        var atLineStart = true
        for ch in s {
            if atLineStart, ch.isLetter {
                out += ch.uppercased()
                atLineStart = false
            } else {
                out.append(ch)
                if ch == "\n" { atLineStart = true } else if !ch.isWhitespace { atLineStart = false }
            }
        }
        return out
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    fileprivate static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
