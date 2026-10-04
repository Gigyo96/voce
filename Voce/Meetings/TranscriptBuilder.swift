import FluidAudio
import Foundation

/// Una parola riconosciuta con i suoi istanti (secondi dall'inizio della riunione).
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// Un intervallo in cui parla un solo parlante (uscita della diarizzazione).
struct SpeakerSpan: Equatable, Sendable {
    var speaker: String
    var start: Double
    var end: Double
}

/// Dalle parole con i tempi e da «chi parla quando» agli interventi della trascrizione.
enum TranscriptBuilder {
    /// Pausa oltre la quale lo stesso parlante comincia un nuovo intervento.
    static let maxGap = 1.6
    /// Lunghezza oltre la quale si va a capo alla prima fine di frase.
    static let maxChars = 400
    /// Una parola lontana più di così da ogni intervallo di parlato non viene attribuita a nessuno vicino.
    static let maxSnap = 1.5

    static func words(from tokens: [TokenTiming], offset: Double) -> [TimedWord] {
        buildWordTimings(from: tokens).map { TimedWord(text: $0.word, start: $0.startTime + offset, end: $0.endTime + offset) }
    }

    /// Ogni parola va al parlante che parla nel suo punto medio; se cade in una pausa, a quello più vicino.
    /// `spans` deve essere ordinato per inizio.
    static func assign(_ words: [TimedWord], to spans: [SpeakerSpan], fallback: String) -> [(word: TimedWord, speaker: String)] {
        guard !spans.isEmpty else { return words.map { ($0, fallback) } }
        var out: [(TimedWord, String)] = []
        var first = 0   // le parole sono in ordine: gli intervalli già finiti non servono più
        for word in words {
            let mid = (word.start + word.end) / 2
            while first < spans.count - 1, spans[first].end < mid - maxSnap { first += 1 }
            var best: (speaker: String, distance: Double)?
            for span in spans[first...] {
                if span.start > mid + maxSnap { break }
                let distance = mid < span.start ? span.start - mid : max(0, mid - span.end)
                if best == nil || distance < best!.distance { best = (span.speaker, distance) }
                if distance == 0 { break }
            }
            out.append((word, best.map { $0.distance <= maxSnap ? $0.speaker : fallback } ?? fallback))
        }
        return out
    }

    /// Raggruppa le parole consecutive dello stesso parlante in interventi.
    static func utterances(_ tagged: [(word: TimedWord, speaker: String)], firstID: Int = 0) -> [Meeting.Utterance] {
        var out: [Meeting.Utterance] = []
        var current: (speaker: String, start: Double, end: Double, words: [String])?
        func flush() {
            guard let c = current, !c.words.isEmpty else { return }
            out.append(Meeting.Utterance(id: firstID + out.count, speaker: c.speaker, start: c.start, end: c.end,
                                         text: c.words.joined(separator: " ")))
            current = nil
        }
        for (word, speaker) in tagged {
            if let c = current {
                let long = c.words.joined(separator: " ").count > maxChars && (c.words.last.map(endsSentence) ?? false)
                if c.speaker != speaker || word.start - c.end > maxGap || long { flush() }
            }
            if current == nil { current = (speaker, word.start, word.end, []) }
            current!.words.append(word.text)
            current!.end = max(current!.end, word.end)
        }
        flush()
        return out
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?…".contains(last)
    }

    /// Rete di sicurezza dopo il filtro dell'eco sull'audio: le parole del microfono che l'altra traccia ha appena detto
    /// (stessa parola entro `within` secondi) sono l'eco dell'altoparlante, non tua. Si tolgono le parole il cui vicinato
    /// (3 parole per lato, solo quelle di almeno 3 lettere) coincide per metà o più. Il microfono sente l'eco con errori
    /// di riconoscimento diversi: per questo conta il vicinato, non la singola parola.
    static func removeEcho(from mic: [TimedWord], against system: [TimedWord], within: Double = 1.5) -> [TimedWord] {
        func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        var times: [String: [Double]] = [:]
        for w in system { times[norm(w.text), default: []].append(w.start) }
        let words = mic.map { norm($0.text) }
        let matched = mic.indices.map { i in
            words[i].count >= 3 && (times[words[i]] ?? []).contains { abs($0 - mic[i].start) <= within }
        }
        // Una parola è eco se coincide con l'altra traccia e anche metà del suo vicinato (3 per lato, parole di 3+ lettere)...
        var echo = mic.indices.map { i -> Bool in
            guard matched[i] else { return false }
            let long = (max(0, i - 3)...min(mic.count - 1, i + 3)).filter { words[$0].count >= 3 }
            return long.count >= 2 && Double(long.filter { matched[$0] }.count) / Double(long.count) >= 0.5
        }
        // ...e lo sono anche quelle riconosciute male in mezzo a due parole d'eco (entro 2 posizioni per lato).
        let core = echo
        for i in mic.indices where !core[i] {
            let before = (max(0, i - 2)..<i).contains { core[$0] }
            let after = ((i + 1)..<min(mic.count, i + 3)).contains { core[$0] }
            if before && after { echo[i] = true }
        }
        return mic.indices.filter { !echo[$0] }.map { mic[$0] }
    }

    /// Più tracce (la tua voce, gli altri) in un'unica trascrizione, in ordine di tempo.
    static func merge(_ lists: [[Meeting.Utterance]]) -> [Meeting.Utterance] {
        let sorted = lists.flatMap { $0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return sorted.enumerated().map { i, u in var u = u; u.id = i; return u }
    }

    /// Parlanti nell'ordine in cui compaiono: ids «s1», «s2»… al posto di quelli del diarizzatore.
    static func renumber(_ spans: [SpeakerSpan]) -> [SpeakerSpan] {
        var names: [String: String] = [:]
        return spans.sorted { $0.start < $1.start }.map { span in
            if names[span.speaker] == nil { names[span.speaker] = "s\(names.count + 1)" }
            return SpeakerSpan(speaker: names[span.speaker]!, start: span.start, end: span.end)
        }
    }
}
