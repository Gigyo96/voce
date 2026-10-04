import Foundation
import Testing
@testable import Voce

// Trascrizione: arbitrato del boosting CTC e segmentazione delle dettature lunghe.

@Suite struct BoostingArbitrationTests {
    let vocab = Transcriber.vocabulary(for: PersonalDictionary(
        terms: ["Supabase", "PostgreSQL", "Claude Code", "kubectl"], replace: ["cube cuttle": "kubectl"]))

    @Test func keepsPunctuationAndPrepositions() {
        // Casi reali dal rescorer di FluidAudio su audio italiano.
        let raw = "Leggi lo userid da super base, poi migra il database a PostgreSQL con Cloud Code e lancia CubeCutle."
        let pairs = [("super base,", "Supabase"), ("a PostgreSQL", "PostgreSQL"), ("database", "Supabase"),
                     ("Cloud Code", "Claude Code"), ("CubeCutle", "kubectl"), ("M, aggiungi uno", "Claude Code")]
            .map { (original: $0.0, term: $0.1) }
        #expect(Transcriber.applyReplacements(pairs, to: raw, vocabulary: vocab)
            == "Leggi lo userid da Supabase, poi migra il database a PostgreSQL con Claude Code e lancia kubectl.")
    }

    @Test func similarity() {
        #expect(Transcriber.similarity("supabase", "supabase") == 1)
        #expect(Transcriber.similarity("database", "supabase") < Transcriber.minSimilarity)
        #expect(Transcriber.similarity("cloudcode", "claudecode") >= Transcriber.minSimilarity)
    }
}

@Suite struct SegmenterTests {
    @Test func cutsInTheQuietestPoint() {
        // 16 s di "voce" con una pausa a 10 s: il taglio deve cadere nella pausa.
        var s = (0..<(16 * 16_000)).map { i in Float(sin(Double(i) * 0.05)) * 0.3 }
        for i in (10 * 16_000)..<(10 * 16_000 + 4_000) { s[i] = 0 }
        let cut = Segmenter.cutPoint(s)
        #expect(cut >= 10 * 16_000 && cut <= 10 * 16_000 + 4_000)
    }

    @Test func joinsSegments() {
        #expect(Segmenter.join(["Prima parte senza punto", "Seconda parte.", "Terza."]) == "Prima parte senza punto seconda parte. Terza.")
        #expect(Segmenter.join(["Usa la", "API di Groq", ""]) == "Usa la API di Groq")
    }
}

@Suite struct MediaPauseTests {
    @Test func recognizesMediaAppsAndTheirHelpers() {
        #expect(MediaPause.isMediaApp("com.spotify.client"))
        #expect(MediaPause.isMediaApp("com.google.Chrome.helper"))
        #expect(MediaPause.isMediaApp("com.apple.WebKit.GPU"))
        #expect(MediaPause.isMediaApp("com.apple.Music"))
        // Chiamate e app qualsiasi: solo volume abbassato, niente Play/Pausa (potrebbe avviare Musica).
        #expect(!MediaPause.isMediaApp("us.zoom.xos"))
        #expect(!MediaPause.isMediaApp("com.apple.FaceTime"))
        #expect(!MediaPause.isMediaApp("com.spotify.clientx"))
    }

    @Test func coreAudioAnswers() {
        #expect(SystemAudio.defaultOutput != nil)
        _ = SystemAudio.playingBundleIDs()   // non deve bloccarsi né andare in crash
    }
}

@Suite struct LivePreviewTests {
    @Test func formatsLikeTheFinalText() {
        let dict = PersonalDictionary(terms: ["useEffect"], replace: [:])
        let out = LivePreview.format(["ehm aggiungi uno use effect", "Che carica i dati a capo poi"], dictionary: dict, language: .auto)
        #expect(out == "Aggiungi uno useEffect che carica i dati\nPoi")
    }

    @Test func tailKeepsTheEndAndStartsAtAWord() {
        let text = (1...60).map { "parola\($0)" }.joined(separator: " ")
        let tail = LivePreview.tail(text, limit: 40)
        #expect(tail.hasPrefix("…parola"))
        #expect(tail.hasSuffix("parola60"))
        #expect(tail.count <= 41)
        #expect(LivePreview.tail("breve") == "breve")
        #expect(LivePreview.tail("riga\nnuova") == "riga ⏎ nuova")
    }
}
