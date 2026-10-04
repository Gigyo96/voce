import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import Voce

// Riunioni: attribuzione dei parlanti, filtro dell'eco, contesto per il modello, chat in streaming, file audio.

@Suite struct TranscriptBuilderTests {
    private func word(_ t: String, _ s: Double, _ e: Double) -> TimedWord { TimedWord(text: t, start: s, end: e) }

    @Test func wordsFromTokens() {
        let tokens = [TokenTiming(token: "▁Ciao", tokenId: 1, startTime: 0.1, endTime: 0.3, confidence: 1),
                      TokenTiming(token: "▁a", tokenId: 2, startTime: 0.4, endTime: 0.5, confidence: 1),
                      TokenTiming(token: "▁tut", tokenId: 3, startTime: 0.5, endTime: 0.7, confidence: 1),
                      TokenTiming(token: "ti", tokenId: 4, startTime: 0.7, endTime: 0.8, confidence: 1),
                      TokenTiming(token: ".", tokenId: 5, startTime: 0.8, endTime: 0.9, confidence: 1)]
        let words = TranscriptBuilder.words(from: tokens, offset: 10)
        #expect(words.map(\.text) == ["Ciao", "a", "tutti."])
        #expect(words[2].start == 10.5 && words[2].end == 10.9)
    }

    @Test func assignsWordsToTheSpeakerWhoIsTalking() {
        let spans = [SpeakerSpan(speaker: "s1", start: 0, end: 5), SpeakerSpan(speaker: "s2", start: 5.2, end: 9)]
        let words = [word("uno", 1, 1.4), word("due", 4.8, 5.1), word("tre", 5.3, 5.6), word("quattro", 8, 8.5)]
        let tagged = TranscriptBuilder.assign(words, to: spans, fallback: "s9")
        #expect(tagged.map(\.speaker) == ["s1", "s1", "s2", "s2"])   // «due» cade nella pausa: il più vicino è s1
    }

    @Test func farFromEveryoneFallsBack() {
        let spans = [SpeakerSpan(speaker: "s1", start: 0, end: 2)]
        let tagged = TranscriptBuilder.assign([word("tardi", 20, 20.4)], to: spans, fallback: "me")
        #expect(tagged.first?.speaker == "me")
        #expect(TranscriptBuilder.assign([word("x", 1, 2)], to: [], fallback: "me").first?.speaker == "me")
    }

    @Test func groupsIntoUtterances() {
        let tagged: [(word: TimedWord, speaker: String)] = [
            (word("Buongiorno", 0, 0.8), "s1"), (word("a", 0.9, 1.0), "s1"), (word("tutti.", 1.0, 1.5), "s1"),
            (word("Grazie.", 1.8, 2.3), "s2"),
            (word("Ora", 2.4, 2.6), "s1"),
            (word("parliamo", 10, 10.5), "s1"),   // stessa persona dopo una lunga pausa: nuovo intervento
        ]
        let u = TranscriptBuilder.utterances(tagged)
        #expect(u.map(\.text) == ["Buongiorno a tutti.", "Grazie.", "Ora", "parliamo"])
        #expect(u.map(\.speaker) == ["s1", "s2", "s1", "s1"])
        #expect(u[0].start == 0 && u[0].end == 1.5)
        #expect(u.map(\.id) == [0, 1, 2, 3])
    }

    @Test func splitsVeryLongRunsAtSentenceEnds() {
        var tagged: [(word: TimedWord, speaker: String)] = []
        for i in 0..<200 { tagged.append((word(i % 20 == 19 ? "fine." : "parola", Double(i) * 0.4, Double(i) * 0.4 + 0.3), "s1")) }
        let u = TranscriptBuilder.utterances(tagged)
        #expect(u.count > 1)
        #expect(u.dropLast().allSatisfy { $0.text.hasSuffix(".") })
    }

    @Test func dropsMicWordsThatTheOtherTrackJustSaid() {
        func words(_ text: String, from start: Double) -> [TimedWord] {
            text.split(separator: " ").enumerated().map { TimedWord(text: String($0.element), start: start + Double($0.offset) * 0.4, end: start + Double($0.offset) * 0.4 + 0.3) }
        }
        let system = words("Come posso dirti odio per il Moloch burocratico senza nessuna capacità", from: 10)
        // L'eco, riconosciuta con qualche errore, e subito dopo una frase davvero tua.
        let mic = words("Come posso dirti odio per il Mulok burocratico senza capacità", from: 10.3)
            + words("Va bene allora procediamo con il preventivo", from: 30)
        let kept = TranscriptBuilder.removeEcho(from: mic, against: system).map(\.text)
        #expect(kept == ["Va", "bene", "allora", "procediamo", "con", "il", "preventivo"])
    }

    @Test func aWordInCommonIsNotEnoughToDropYourSentence() {
        let system = [TimedWord(text: "progetto", start: 5, end: 5.5)]
        let mic = [TimedWord(text: "Il", start: 5, end: 5.1), TimedWord(text: "progetto", start: 5.1, end: 5.5),
                   TimedWord(text: "parte", start: 5.5, end: 5.9), TimedWord(text: "domani", start: 5.9, end: 6.3),
                   TimedWord(text: "mattina", start: 6.3, end: 6.7)]
        #expect(TranscriptBuilder.removeEcho(from: mic, against: system).count == 5)
    }

    @Test func mergesTracksInTimeOrderAndRenumbers() {
        let mine = [Meeting.Utterance(id: 0, speaker: "me", start: 5, end: 6, text: "io")]
        let theirs = [Meeting.Utterance(id: 0, speaker: "s1", start: 1, end: 2, text: "loro"),
                      Meeting.Utterance(id: 1, speaker: "s1", start: 9, end: 10, text: "ancora")]
        let merged = TranscriptBuilder.merge([mine, theirs])
        #expect(merged.map(\.text) == ["loro", "io", "ancora"])
        #expect(merged.map(\.id) == [0, 1, 2])

        let spans = TranscriptBuilder.renumber([SpeakerSpan(speaker: "S7", start: 3, end: 4), SpeakerSpan(speaker: "S2", start: 1, end: 2),
                                                SpeakerSpan(speaker: "S7", start: 5, end: 6)])
        #expect(spans.map(\.speaker) == ["s1", "s2", "s2"])   // in ordine di comparsa: S2 parla per primo
    }
}

@Suite struct EchoGateTests {
    static let rate = 16_000

    /// Rumore deterministico (LCG) di ampiezza `amp`.
    static func noise(_ seconds: Double, amp: Float, seed: UInt32 = 1) -> [Float] {
        var x = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            x = x &* 1_664_525 &+ 1_013_904_223
            return (Float(x >> 8) / Float(1 << 24) - 0.5) * 2 * amp
        }
    }

    /// Audio del Mac: due «voci» a rumore con silenzi in mezzo (1–9 s e 11–19 s su 24 s).
    static func system() -> [Float] {
        var s = [Float](repeating: 0, count: 24 * rate)
        for (a, b) in [(1, 9), (11, 19)] { s.replaceSubrange(a * rate..<b * rate, with: noise(Double(b - a), amp: 0.25, seed: UInt32(a))) }
        return s
    }

    /// L'altoparlante come lo sente il microfono: ritardo di 60 ms più riflessioni che decadono in 150 ms, un po' di
    /// saturazione e rumore di fondo. `gain` è il rientro (0,6 = molto forte, tipico dei portatili).
    static func echo(of system: [Float], gain: Float, delay: Int = 960) -> [Float] {
        var taps: [(Int, Float)] = [(delay, 1)]
        var x: UInt32 = 77
        for _ in 0..<40 {
            x = x &* 1_664_525 &+ 1_013_904_223
            let d = Int(x >> 16) % 2_400
            x = x &* 1_664_525 &+ 1_013_904_223
            let sign: Float = (x >> 20) % 2 == 0 ? 1 : -1
            taps.append((delay + d, sign * 0.25 * Float(exp(-Double(d) / 800))))
        }
        var out = [Float](repeating: 0, count: system.count)
        for (d, a) in taps { for i in d..<system.count { out[i] += a * system[i - d] } }
        let floor = noise(Double(system.count) / Double(rate), amp: 0.002, seed: 5)
        return out.indices.map { i in tanhf(3 * gain * out[i]) / 3 + floor[i] }
    }

    func energy(_ x: [Float], from: Double, to: Double) -> Float {
        x[Int(from * Double(Self.rate))..<Int(to * Double(Self.rate))].reduce(0) { $0 + $1 * $1 }
    }

    @Test func findsTheDelayOfTheEcho() throws {
        let system = Self.system()
        let lag = try #require(EchoGate.lag(mic: Self.echo(of: system, gain: 0.6), system: system))
        #expect(abs(lag - 960) <= 2)
    }

    @Test func removesAStrongEchoWhenNobodySpeaks() {
        let system = Self.system()
        let mic = Self.echo(of: system, gain: 0.6)
        let out = EchoGate.apply(mic: mic, system: system)
        #expect(energy(out, from: 2, to: 8) < 0.05 * energy(mic, from: 2, to: 8))
        #expect(energy(out, from: 12, to: 18) < 0.05 * energy(mic, from: 12, to: 18))
    }

    @Test func removesAWeakEchoToo() {
        let system = Self.system()
        let mic = Self.echo(of: system, gain: 0.05)
        #expect(energy(EchoGate.apply(mic: mic, system: system), from: 2, to: 8) < 0.05 * energy(mic, from: 2, to: 8))
    }

    @Test func keepsYourVoiceAfterAndOverTheOthers() {
        let system = Self.system()
        var mic = Self.echo(of: system, gain: 0.6)
        // Tu: da solo a 20–23 s e sopra l'altro a 13–17 s.
        for (a, b, amp) in [(20, 23, Float(0.2)), (13, 17, Float(0.5))] {
            let voice = Self.noise(Double(b - a), amp: amp, seed: UInt32(b))
            for i in 0..<voice.count { mic[a * Self.rate + i] += voice[i] }
        }
        let out = EchoGate.apply(mic: mic, system: system)
        #expect(energy(out, from: 20.3, to: 22.7) > 0.9 * energy(mic, from: 20.3, to: 22.7))
        #expect(energy(out, from: 13.7, to: 16.3) > 0.9 * energy(mic, from: 13.7, to: 16.3))
        #expect(energy(out, from: 2, to: 8) < 0.05 * energy(mic, from: 2, to: 8))   // e l'eco resta tolta
    }

    @Test func headphonesLeaveTheMicAlone() {
        let system = Self.system()
        let mic = Self.noise(24, amp: 0.2, seed: 9)   // nessun legame con l'audio del Mac
        #expect(EchoGate.lag(mic: mic, system: system) == nil)
        #expect(EchoGate.apply(mic: mic, system: system) == mic)
    }

    @Test func shortAudioIsUntouched() {
        let mic = Self.noise(2, amp: 0.2)
        #expect(EchoGate.apply(mic: mic, system: Self.noise(2, amp: 0.2, seed: 3)) == mic)
    }
}

@Suite struct MeetingModelTests {
    private func sample() -> Meeting {
        var m = Meeting(id: "t", title: "Prova", createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: .recorded, state: .ready)
        m.speakers = [.init(id: "me"), .init(id: "s1", name: "Marco"), .init(id: "s2")]
        m.utterances = [.init(id: 0, speaker: "s1", start: 0, end: 4, text: "Buongiorno."),
                        .init(id: 1, speaker: "me", start: 4, end: 6, text: "Ciao Marco."),
                        .init(id: 2, speaker: "s2", start: 70, end: 75, text: "Eccomi.")]
        return m
    }

    @Test func namesAndDefaults() {
        let m = sample()
        #expect(m.name(of: "s1") == "Marco")
        #expect(m.name(of: "s2") == Meeting.defaultName("s2"))
        #expect(m.name(of: "me") == L("Io"))
        #expect(Meeting.defaultName("s2").hasSuffix("2"))
    }

    @Test func mergeMovesRemarksAndDropsTheEmptySpeaker() {
        var m = sample()
        m.merge("s2", into: "s1")
        #expect(m.utterances.map(\.speaker) == ["s1", "me", "s1"])
        #expect(m.speakers.map(\.id) == ["me", "s1"])
    }

    @Test func newSpeakerGetsAFreshID() {
        var m = sample()
        #expect(m.addSpeaker() == "s3")
    }

    @Test func clockAndText() {
        #expect(Meeting.clock(65) == "01:05")
        #expect(Meeting.clock(3_725) == "1:02:05")
        #expect(sample().transcriptText().hasPrefix("[00:00] Marco: Buongiorno."))
        #expect(sample().markdown().contains("**Marco** (00:00): Buongiorno."))
    }

    @Test func survivesJSON() throws {
        var m = sample()
        let at = Date(timeIntervalSince1970: 1_700_000_100)   // il JSON tiene i secondi interi
        m.chat = [.init(role: .user, text: "Chi c'era?", date: at), .init(role: .assistant, text: "Marco.", date: at)]
        m.tracks = [.init(kind: .mic, file: "mic.caf", offset: 0.04)]
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(Meeting.self, from: enc.encode(m)) == m)
    }

    @Test func absolutePathsResolveToThemselves() {
        #expect(sample().url("/tmp/a.wav").path == "/tmp/a.wav")
        #expect(sample().url("a.wav").path.hasSuffix("meetings/t/a.wav"))
    }
}

@Suite struct MeetingContextTests {
    private func meeting(lines: Int) -> Meeting {
        var m = Meeting(id: "c", title: "Lungo", createdAt: Date(), source: .recorded, state: .ready)
        m.speakers = [.init(id: "s1", name: "Anna"), .init(id: "s2", name: "Bruno")]
        m.utterances = (0..<lines).map { i in
            Meeting.Utterance(id: i, speaker: i % 2 == 0 ? "s1" : "s2", start: Double(i) * 10, end: Double(i) * 10 + 8,
                              text: i == 37 ? "Il fornitore ha confermato la consegna del server entro marzo." : "Discussione generica numero \(i) sul calendario.")
        }
        return m
    }

    @Test func budgetFromTokens() {
        #expect(MeetingContext.budget(tokens: 16_000) == 33_600)
    }

    @Test func chunksRespectTheLimitAndKeepEveryLine() {
        let m = meeting(lines: 100)
        let chunks = MeetingContext.chunks(of: m, maxChars: 1_000)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.text.count <= 1_000 })
        #expect(chunks.reduce(0) { $0 + $1.text.split(separator: "\n").count } == 100)
        #expect(chunks.map(\.start) == chunks.map(\.start).sorted())
    }

    @Test func findsThePassageThatMentionsTheQuestion() {
        let m = meeting(lines: 100)
        let chunks = MeetingContext.chunks(of: m, maxChars: 800)
        let hits = MeetingContext.relevant(to: "Quando consegna il fornitore il server?", in: chunks, maxChars: 1_600)
        #expect(hits.contains { $0.text.contains("fornitore ha confermato") })
        #expect(hits.map(\.text).joined().count <= 1_600)
        #expect(MeetingContext.relevant(to: "e se poi", in: chunks, maxChars: 1_000).isEmpty)   // solo parole vuote
    }

    @Test func stemsAbsorbInflection() {
        #expect(Set(MeetingContext.stems("decisioni")).isSubset(of: Set(MeetingContext.stems("la decisione presa"))))
    }

    @Test func shortMeetingsGoInFull() {
        let m = meeting(lines: 5)
        #expect(MeetingContext.fits(m, budget: 10_000))
        #expect(MeetingContext.material(for: m, question: "x", budget: 10_000).hasPrefix("TRASCRIZIONE:"))
    }

    @Test func longMeetingsGetNotesAndExcerpts() {
        var m = meeting(lines: 400)
        m.digest = ["- Anna e Bruno discutono il calendario (00:00)"]
        let text = MeetingContext.material(for: m, question: "Cosa ha detto il fornitore sul server?", budget: 3_000)
        #expect(text.contains("APPUNTI DELL'INTERA RIUNIONE"))
        #expect(text.contains("fornitore ha confermato"))
        #expect(text.count < 3_400)
    }
}

@Suite struct MeetingAssistantTests {
    @Test func splitsTheTitleFromTheSummary() {
        let (title, body) = MeetingAssistant.splitTitle("# Lancio del prodotto\n\n## Sintesi\nSi è deciso il 15 novembre.\n")
        #expect(title == "Lancio del prodotto")
        #expect(body == "## Sintesi\nSi è deciso il 15 novembre.")
        #expect(MeetingAssistant.splitTitle("## Sintesi\nTesto").title == nil)
    }

    @Test func parsesNamesEvenWithNoiseAroundTheJSON() {
        #expect(MeetingAssistant.parseNames("Ecco:\n```json\n{\"s1\": \"Marco\", \"s2\": null, \"me\": \" \"}\n```") == ["s1": "Marco"])
        #expect(MeetingAssistant.parseNames("non lo so").isEmpty)
    }
}

@Suite struct StreamingTests {
    @Test func readsDeltasFromServerSentEvents() {
        #expect(LLMClient.delta(inSSELine: #"data: {"choices":[{"delta":{"content":"Ciao"}}]}"#) == "Ciao")
        #expect(LLMClient.delta(inSSELine: #"data:{"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(LLMClient.delta(inSSELine: "data: [DONE]") == nil)
        #expect(LLMClient.delta(inSSELine: ": keep-alive") == nil)
        #expect(LLMClient.delta(inSSELine: "") == nil)
        #expect(LLMClient.delta(inSSELine: "data: {rotto") == nil)
    }

    @Test func hidesThinkingWhileItStreams() {
        #expect(Guardrail.visible("<think>ragiono") == "")
        #expect(Guardrail.visible("<think>ragiono</think>\n\nRisposta") == "Risposta")
        #expect(Guardrail.visible("Risposta <think>x</think>finale") == "Risposta finale")
    }
}

@Suite struct MarkdownBlocksTests {
    @Test func parsesHeadingsListsAndTasks() {
        let blocks = MarkdownText.blocks("""
            ## Decisioni
            - Lancio il **15 novembre**
              - Sotto-punto
            - [ ] Luca: piano di comunicazione
            - [x] Marco: budget

            Testo che va
            a capo.
            1. Primo
            """)
        #expect(blocks == [
            .heading(2, "Decisioni"),
            .bullet(indent: 0, marker: "•", text: "Lancio il **15 novembre**"),
            .bullet(indent: 1, marker: "•", text: "Sotto-punto"),
            .bullet(indent: 0, marker: "☐", text: "Luca: piano di comunicazione"),
            .bullet(indent: 0, marker: "☑", text: "Marco: budget"),
            .paragraph("Testo che va a capo."),
            .bullet(indent: 0, marker: "1.", text: "Primo"),
        ])
    }
}

@Suite struct MeetingAudioTests {
    private func tempURL(_ name: String) -> URL { FileManager.default.temporaryDirectory.appending(path: "voce-test-\(UUID().uuidString)-\(name)") }

    @Test func convertsAnyFormatTo16kMono() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for c in 0..<2 { for i in 0..<4_800 { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.1)) * 0.5 } }
        let converter = try #require(PCMConverter(from: format))
        let out = (0..<10).flatMap { _ in converter.convert(buffer) }
        #expect(abs(out.count - 16_000) < 400)   // 1 s a 16 kHz (il primo buffer include l'avvio del ricampionatore)
        #expect(out.contains { abs($0) > 0.1 })
    }

    @Test func trackWriterFileCanBeReadBack() async throws {
        let url = tempURL("track.caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url)
        let tone = (0..<16_000).map { Float(sin(Double($0) * 0.2)) * 0.4 }
        writer.append(tone, hostTime: 1_000)
        writer.append(tone, hostTime: 2_000)
        #expect(writer.firstHostTime == 1_000)
        #expect(abs(writer.seconds - 2) < 0.001)
        #expect(writer.hasSignal)
        #expect(writer.consumeLevel() > 0.3)
        writer.close()
        let back = try Transcriber.loadAudio(url.path)
        #expect(abs(back.count - 32_000) < 200)
        #expect(back.contains { abs($0) > 0.3 })
    }

    @Test func mutedTrackStaysAlignedButSilent() throws {
        let url = tempURL("muted.caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url)
        writer.setMuted(true)
        writer.append([Float](repeating: 0.5, count: 16_000), hostTime: 1)
        writer.close()
        let back = try Transcriber.loadAudio(url.path)
        #expect(back.count > 15_000)
        #expect(back.allSatisfy { abs($0) < 0.001 })
    }

    @Test func mixIsCompressedAndReadable() async throws {
        let url = tempURL("mix.m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = (0..<48_000).map { Float(sin(Double($0) * 0.1)) * 0.3 }
        let b = [Float](repeating: 0, count: 16_000) + (0..<16_000).map { Float(sin(Double($0) * 0.3)) * 0.3 }
        #expect(try MeetingPipeline.writeMix([a, b], to: url))
        let back = try await AudioFileLoader.samples(at: url)
        #expect(abs(back.count - 48_000) < 2_000)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? .max) < 30_000)
        #expect(try MeetingPipeline.writeMix([], to: url) == false)
    }

    @Test func capitalisationContinuesAcrossSegments() {
        #expect(Segmenter.continuing("Di sopra", after: "Parlavamo del progetto") == "di sopra")
        #expect(Segmenter.continuing("Di sopra", after: "Fine frase.") == "Di sopra")
        #expect(Segmenter.continuing("API", after: "Usiamo le") == "API")
    }
}

@Suite struct MediaModeTests {
    @Test func targetVolumes() {
        #expect(MediaMode.target(.off, level: 20, original: 0.8) == 0.8)
        #expect(MediaMode.target(.pause, level: 20, original: 0.8) == 0)
        #expect(abs(MediaMode.target(.lower, level: 20, original: 0.8) - 0.16) < 0.0001)
        #expect(abs(MediaMode.target(.lower, level: 10, original: 0.5) - 0.05) < 0.0001)
        #expect(MediaMode.target(.lower, level: 250, original: 0.5) == 0.5)    // mai più alto dell'originale
        #expect(MediaMode.target(.lower, level: -5, original: 0.5) == 0)
    }

    @Test func oldToggleMigratesToTheNewMode() throws {
        let off = try #require(UserDefaults(suiteName: "voce-test-\(UUID().uuidString)"))
        off.set(false, forKey: "pauseMedia")
        Prefs.migrateMediaMode(off)
        #expect(off.string(forKey: Prefs.mediaMode.key) == MediaMode.off.rawValue)
        #expect(off.object(forKey: "pauseMedia") == nil)

        let on = try #require(UserDefaults(suiteName: "voce-test-\(UUID().uuidString)"))
        on.set(true, forKey: "pauseMedia")
        Prefs.migrateMediaMode(on)
        #expect(on.string(forKey: Prefs.mediaMode.key) == MediaMode.pause.rawValue)

        let chosen = try #require(UserDefaults(suiteName: "voce-test-\(UUID().uuidString)"))
        chosen.set(true, forKey: "pauseMedia")
        chosen.set(MediaMode.lower.rawValue, forKey: Prefs.mediaMode.key)
        Prefs.migrateMediaMode(chosen)
        #expect(chosen.string(forKey: Prefs.mediaMode.key) == MediaMode.lower.rawValue)   // una scelta già fatta non si tocca
    }
}
