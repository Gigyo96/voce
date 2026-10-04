import Accelerate
import Foundation

/// Senza cuffie il microfono risente degli altoparlanti: le voci degli altri finirebbero trascritte due volte, come se le
/// avessi dette tu (un parlante in più, con un testo di cattiva qualità). Il filtro azzera i pezzi del microfono che sono
/// solo l'eco dell'audio del Mac.
///
/// Non si fida dei livelli (dipendono da volume, guadagno e distanza del microfono) ma della **coerenza spettrale**:
/// l'eco è una versione filtrata e ritardata dell'audio del Mac, quindi i due segnali sono fortemente correlati
/// frequenza per frequenza; due voci indipendenti no. Passi:
/// 1. il ritardo microfono ↔ audio del Mac si stima con una correlazione generalizzata (GCC-PHAT) sul pezzo più
///    sonoro; se non c'è un picco netto non c'è eco (cuffie) e il microfono resta com'è;
/// 2. ogni mezzo secondo si misura la coerenza su 1,5 s; se l'audio del Mac suona e la coerenza è alta, quel pezzo di
///    microfono è eco e si azzera. Se parli sopra gli altri la coerenza scende e il pezzo resta.
enum EchoGate {
    static let rate = 16_000
    /// Livello (RMS) sotto il quale l'audio del Mac è silenzio.
    static let speechLevel: Float = 0.004
    /// Coerenza media (0…1) oltre la quale il microfono è considerato eco. Due segnali indipendenti stanno sotto 0,1.
    static let threshold: Float = 0.3
    /// Quanto deve spiccare il picco di correlazione sul fondo per credere a un'eco.
    static let minPeakRatio: Float = 7

    private static let frame = 2048
    private static let hop = 1024
    private static let slice = 8 * hop                // 0,512 s: unità di decisione
    private static let band = 26..<512                // 200–4000 Hz con FFT da 2048 a 16 kHz

    static func apply(mic: [Float], system: [Float]) -> [Float] {
        guard let lag = lag(mic: mic, system: system) else { return mic }
        let coherence = sliceCoherence(mic: mic, system: system, lag: lag)
        var out = mic
        for (i, c) in coherence.enumerated() where c.systemActive && c.value >= threshold {
            let end = min(out.count, (i + 1) * slice)
            for j in (i * slice)..<end { out[j] = 0 }
        }
        return out
    }

    // MARK: Ritardo (GCC-PHAT)

    /// Campioni di cui il microfono ritarda rispetto all'audio del Mac, o `nil` se non c'è un'eco riconoscibile.
    static func lag(mic: [Float], system: [Float]) -> Int? {
        let count = min(mic.count, system.count)
        guard count >= 6 * rate else { return nil }
        let size = 1 << 20
        let window = min(count, size / 2)
        // Il pezzo in cui l'audio del Mac suona di più: lì l'eco, se c'è, si vede meglio.
        let second = rate
        let energy = (0..<(count / second)).map { s in
            system[(s * second)..<((s + 1) * second)].reduce(Float(0)) { $0 + $1 * $1 }
        }
        let span = max(1, window / second)
        var best = 0, bestSum: Float = -1, running = energy.prefix(span).reduce(0, +)
        for s in 0...(max(0, energy.count - span)) {
            if s > 0, s + span - 1 < energy.count { running += energy[s + span - 1] - energy[s - 1] }
            if running > bestSum { bestSum = running; best = s }
        }
        let start = min(best * second, count - window)

        let fft = RealFFT(log2n: 20)
        // Riempiti di zeri fino a `size`: la correlazione è lineare, non circolare.
        func padded(_ x: [Float]) -> [Float] { Array(x[start..<(start + window)]) + [Float](repeating: 0, count: size - window) }
        var (mr, mi) = fft.forward(padded(mic))
        let (sr, si) = fft.forward(padded(system))
        // C = M · conj(S): c[τ] = Σ mic[t]·sys[t−τ]; PHAT: solo la fase, solo la banda del parlato.
        let lo = 100 * size / rate, hi = 4_000 * size / rate
        for k in 0..<(size / 2) {
            guard k >= lo, k < hi else { mr[k] = 0; mi[k] = 0; continue }
            let re = mr[k] * sr[k] + mi[k] * si[k]
            let im = mi[k] * sr[k] - mr[k] * si[k]
            let magnitude = (re * re + im * im).squareRoot() + 1e-12
            mr[k] = re / magnitude
            mi[k] = im / magnitude
        }
        let c = fft.inverse(re: &mr, im: &mi)

        // Ritardi plausibili: da −0,2 s a +1 s (la scheda audio, il Bluetooth, il tap).
        let lags = (-3_200)...16_000
        func value(_ lag: Int) -> Float { c[(lag + size) % size] }
        guard let peak = lags.max(by: { value($0) < value($1) }) else { return nil }
        var sumSquares: Float = 0, n: Float = 0
        for lag in lags where abs(lag - peak) > 64 { sumSquares += value(lag) * value(lag); n += 1 }
        let floor = (sumSquares / max(n, 1)).squareRoot()
        guard floor > 0, value(peak) / floor >= minPeakRatio else { return nil }
        return peak
    }

    // MARK: Coerenza

    struct SliceCoherence {
        var value: Float
        var systemActive: Bool
    }

    /// Per ogni mezzo secondo: coerenza media (200–4000 Hz) tra microfono e audio del Mac ritardato di `lag`, su 1,5 s.
    static func sliceCoherence(mic: [Float], system: [Float], lag: Int) -> [SliceCoherence] {
        let slices = min(mic.count, system.count) / slice
        guard slices > 0 else { return [] }
        let fft = RealFFT(log2n: 11)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)
        let bins = band.count

        struct Sums { var xx: [Float], yy: [Float], re: [Float], im: [Float], level: Float }
        func sums(_ s: Int) -> Sums {
            var a = Sums(xx: [Float](repeating: 0, count: bins), yy: [Float](repeating: 0, count: bins),
                         re: [Float](repeating: 0, count: bins), im: [Float](repeating: 0, count: bins), level: 0)
            for f in 0..<(slice / hop - 1) {
                let at = s * slice + f * hop
                let x = vDSP.multiply(Array(mic[at..<(at + frame)]), window)
                var y = [Float](repeating: 0, count: frame)
                let from = at - lag
                if from >= 0, from + frame <= system.count { y = Array(system[from..<(from + frame)]) }
                else if from < 0, from + frame > 0 { y.replaceSubrange((-from)..<frame, with: system[0..<(from + frame)]) }
                let (xr, xi) = fft.forward(x)
                let (yr, yi) = fft.forward(vDSP.multiply(y, window))
                for (j, k) in band.enumerated() {
                    a.xx[j] += xr[k] * xr[k] + xi[k] * xi[k]
                    a.yy[j] += yr[k] * yr[k] + yi[k] * yi[k]
                    a.re[j] += xr[k] * yr[k] + xi[k] * yi[k]      // X · conj(Y)
                    a.im[j] += xi[k] * yr[k] - xr[k] * yi[k]
                }
            }
            let end = (s + 1) * slice
            a.level = (system[(s * slice)..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(slice)).squareRoot()
            return a
        }

        let all = (0..<slices).map(sums)
        return (0..<slices).map { s in
            let around = all[max(0, s - 1)...min(slices - 1, s + 1)]
            var weighted: Float = 0, total: Float = 0
            for j in 0..<bins {
                let xx = around.reduce(Float(0)) { $0 + $1.xx[j] }, yy = around.reduce(Float(0)) { $0 + $1.yy[j] }
                let re = around.reduce(Float(0)) { $0 + $1.re[j] }, im = around.reduce(Float(0)) { $0 + $1.im[j] }
                let weight = (xx * yy).squareRoot()
                guard weight > 0 else { continue }
                weighted += (re * re + im * im) / weight      // peso × |Sxy|² / (Sxx·Syy)
                total += weight
            }
            return SliceCoherence(value: total > 0 ? weighted / total : 0, systemActive: around.contains { $0.level > speechLevel })
        }
    }
}

/// FFT reale di vDSP con un'interfaccia a due array (parte reale e immaginaria dei bin 0…n/2, con Nyquist in `im[0]`).
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init(log2n: Int) {
        n = 1 << log2n
        self.log2n = vDSP_Length(log2n)
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `x` ha esattamente `n` campioni.
    func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        precondition(x.count == n, "RealFFT: servono \(n) campioni, ce ne sono \(x.count)")
        let h = n / 2
        var re = [Float](repeating: 0, count: h), im = [Float](repeating: 0, count: h)
        x.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { complex in
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(h))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
        }
        return (re, im)
    }

    /// Antitrasformata; il risultato è in scala arbitraria (conta solo la forma).
    func inverse(re: inout [Float], im: inout [Float]) -> [Float] {
        let h = n / 2
        var out = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(h)) }
                }
            }
        }
        return out
    }
}
