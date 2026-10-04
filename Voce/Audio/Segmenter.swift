import Foundation

/// Trascrizione incrementale (Appendice A): durante una dettatura lunga l'audio si taglia nelle pause
/// e i segmenti si trascrivono mentre l'utente parla; al rilascio resta solo la coda.
enum Segmenter {
    // La coda attesa al rilascio resta sotto i 14 s: una sola finestra (15 s) di TDT e di CTC.
    static let triggerSeconds = 14.0          // si taglia quando l'audio non trascritto supera 14 s
    static let window = (min: 7.0, max: 13.0)  // il taglio cade tra 7 e 13 s, nel punto più silenzioso

    /// Indice di taglio: centro della finestra da 100 ms con energia minima nell'intervallo consentito.
    static func cutPoint(_ s: [Float], sampleRate: Double = 16_000) -> Int {
        let frame = Int(sampleRate / 10)
        let lo = Int(window.min * sampleRate), hi = min(Int(window.max * sampleRate), s.count - frame)
        guard hi > lo else { return min(s.count, lo) }
        var best = lo, bestEnergy = Float.infinity
        var i = lo
        while i <= hi {
            var e: Float = 0
            for j in i..<(i + frame) { e += s[j] * s[j] }
            if e < bestEnergy { bestEnergy = e; best = i }
            i += frame / 2
        }
        return best + frame / 2
    }

    /// Concatena i testi: se il segmento precedente non chiude la frase, la maiuscola "di segmento"
    /// che Parakeet mette all'inizio diventa minuscola (salvo sigle come "API").
    static func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
            guard let last = out.last else { out = part; continue }
            var next = part
            if !".!?…:".contains(last), let f = next.first, f.isUppercase,
               next.dropFirst().first.map({ $0.isLowercase }) ?? false {
                next = f.lowercased() + next.dropFirst()
            }
            out += " " + next
        }
        return out
    }
}
