import Foundation

/// Cronologia delle dettature in JSONL (§8) e dataset personale per `tools/eval.py`.
enum History {
    nonisolated(unsafe) static let iso = ISO8601DateFormatter()   // thread-safe

    struct Entry: Codable, Identifiable, Equatable {
        var ts: String
        var app: String
        var profile: String
        var mode: String
        var raw: String
        var boosted: String?
        var final: String
        var ms: Int          // rilascio del tasto → testo incollato
        var audio_ms: Int
        var asr_ms: Int
        var boost_ms: Int?
        var segments: Int?
        var llm_ms: Int?
        var llm: Bool
        var guardrail: String?

        var id: String { ts + "|" + raw }
        var date: Date? { History.iso.date(from: ts) }
    }

    static func append(_ e: Entry) {
        try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? enc.encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: Paths.history)
        }
    }

    /// Ultime `limit` dettature (dalla coda del file), dalla più vecchia alla più recente.
    static func recent(limit: Int = 300) -> [Entry] {
        guard let h = try? FileHandle(forReadingFrom: Paths.history) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 1 << 20
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if size > window { lines.removeFirst() }   // la prima riga è quasi certamente tagliata
        let dec = JSONDecoder()
        return lines.suffix(limit).compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    static func saveSample(_ samples: [Float], text: String, stamp: String) {
        try? FileManager.default.createDirectory(at: Paths.dataset, withIntermediateDirectories: true)
        try? Recorder.writeWAV(samples, to: Paths.dataset.appending(path: "\(stamp).wav"))
        try? text.write(to: Paths.dataset.appending(path: "\(stamp).txt"), atomically: true, encoding: .utf8)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }
}
