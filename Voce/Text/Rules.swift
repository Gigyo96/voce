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

    // Solo filler non ambigui; "cioè", "tipo", "like" si aggiungono solo se i dati lo giustificano.
    private static let filler = regex(#"(?<![\p{L}\p{N}])(?:e+h*m+|e+h+|(?<!\d )m+|u+h*m+|u+h+)(?![\p{L}\p{N}]),?\s*"#)
    // "a capo" ma non "a capo del/della/di…" (uso normale nel parlato).
    private static let newline = regex(#"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}])a capo(?![\p{L}\p{N}])(?!\s+(?:del|della|dello|dei|degli|delle|di)\b)[.,;:!?]?[ \t]*"#)
    private static let paragraph = regex(#"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}])nuovo paragrafo(?![\p{L}\p{N}])[.,;:!?]?[ \t]*"#)
    private static let send = regex(#"[\s,;:.]*(?<![\p{L}\p{N}])invia(?![\p{L}\p{N}])[.!]?\s*$"#)

    static func apply(_ input: String, profile: Profile, sendOnInvia: Bool) -> RulesOutput {
        var s = input
        var shouldSend = false
        if sendOnInvia, profile.isAgent, s.range(of: send.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            s = replace(send, in: s, with: "")
            shouldSend = true
        }
        s = replace(filler, in: s, with: "")
        s = replace(paragraph, in: s, with: "\n\n")
        s = replace(newline, in: s, with: "\n")
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

    fileprivate static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
