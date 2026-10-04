import AVFoundation

/// Riascolto di una riunione: un punto qualsiasi della trascrizione si può ascoltare.
@MainActor final class MeetingPlayer: ObservableObject {
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loaded: URL?
    /// Dove si ferma un ascolto di prova (il campione di voce di un parlante).
    private var stopAt: TimeInterval?

    func load(_ url: URL?) {
        guard let url, url != loaded else { return }
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        loaded = url
        duration = player?.duration ?? 0
        time = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play(from start: TimeInterval? = nil, until end: TimeInterval? = nil) {
        guard let player else { return }
        if let start { player.currentTime = min(max(0, start), max(0, duration - 0.1)) }
        stopAt = end
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func seek(_ seconds: TimeInterval) {
        player?.currentTime = min(max(0, seconds), duration)
        time = player?.currentTime ?? 0
    }

    func stop() {
        player?.stop()
        player = nil
        loaded = nil
        isPlaying = false
        timer?.invalidate()
        time = 0
    }

    private func tick() {
        guard let player else { return }
        time = player.currentTime
        if let stopAt, time >= stopAt { pause(); self.stopAt = nil }
        if !player.isPlaying { isPlaying = false; timer?.invalidate() }
    }
}
