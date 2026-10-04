import AppKit
import AudioToolbox
import CoreAudio
import IOKit.hidsystem

// MARK: - Audio del Mac durante la dettatura

/// Cosa fare dell'audio del Mac mentre detti (Generale › Audio durante la dettatura).
enum MediaMode: String, CaseIterable, Sendable {
    case off      // non toccarlo
    case pause    // fermarlo del tutto: volume a zero e Play/Pausa
    case lower    // abbassarlo a una percentuale del volume di prima, senza fermarlo

    /// Percentuali tra cui scegliere in modalità `lower`.
    static let levelRange = 0...90
    static let levelStep = 5

    /// Volume da raggiungere partendo da `original` (0…1). `level` è una percentuale del volume originale.
    static func target(_ mode: MediaMode, level: Int, original: Float) -> Float {
        switch mode {
        case .off: return original
        case .pause: return 0
        case .lower: return original * Float(min(max(level, 0), 100)) / 100
        }
    }
}

/// Mentre si detta, l'audio del Mac si ferma o si abbassa e alla fine torna com'era (vedi `MediaMode`).
///
/// - Il volume di uscita sfuma fino al valore scelto (zero, oppure una percentuale dell'originale): vale per
///   qualsiasi fonte (browser, giochi, chiamate…).
/// - Solo in modalità «ferma»: se a suonare è un'app multimediale (Musica, Spotify, un browser…) si preme anche
///   Play/Pausa, così brani, podcast e video non vanno avanti mentre parli; alla fine un secondo Play/Pausa li fa ripartire.
///
/// Solo API pubbliche: `MediaRemote` (lo stato "In riproduzione") da macOS 15.4 non risponde più alle app di terze
/// parti, quindi chi suona si scopre da Core Audio (processi con l'uscita attiva, macOS 14.4+) e la pausa passa dal
/// tasto multimediale, lo stesso della tastiera, che arriva anche a Safari e Chrome.
@MainActor final class MediaPause {
    private struct Ducked {
        let device: AudioObjectID
        let volume: Float32      // volume originale
        let target: Float32      // volume mentre si detta
    }

    private(set) var isActive = false
    private var ducked: Ducked?          // volume originale, finché la dettatura è in corso
    private var restoring: Ducked?       // volume originale, mentre risale dopo la dettatura
    private var lastSet: Float32 = 0     // ultimo volume impostato da Voce: se è cambiato, l'ha cambiato l'utente
    private var pressedPlayPause = false
    private var task: Task<Void, Never>?
    private static let fade: Duration = .milliseconds(250)

    /// Da chiamare quando la dettatura è davvero iniziata (non a ogni pressione: ⌘C col ⌘ destro non deve fermare la musica).
    func begin(mode: MediaMode = Prefs.media, level: Int = Prefs.mediaLevel.value) {
        guard !isActive, mode != .off else { return }
        let playing = SystemAudio.playingBundleIDs()
        guard !playing.isEmpty else { return }
        isActive = true
        task?.cancel()
        let media = mode == .pause && playing.contains(where: Self.isMediaApp)
        log.info("audio \(mode == .pause ? "in pausa" : "abbassato al \(level)%"): \(playing.sorted().joined(separator: ", "))\(media ? " (Play/Pausa)" : "")")

        if let device = SystemAudio.defaultOutput, SystemAudio.canSetVolume(device), let current = SystemAudio.volume(device) {
            // Se il volume stava ancora risalendo dalla dettatura precedente, l'originale è quello di allora.
            let original = restoring?.device == device ? restoring!.volume : current
            let target = MediaMode.target(mode, level: level, original: original)
            if original > 0, target < original {
                ducked = Ducked(device: device, volume: original, target: target)
                lastSet = current
                Self.saveForRecovery(device: device, volume: original, target: target)
            }
        }
        restoring = nil
        task = Task { [weak self] in
            guard let self else { return }
            if let ducked = self.ducked { await self.ramp(ducked.device, to: ducked.target) }
            guard !Task.isCancelled, self.isActive, media else { return }
            MediaKey.playPause()
            self.pressedPlayPause = true
        }
    }

    /// Fine della dettatura (rilascio, annullamento, durata massima): fa ripartire ciò che aveva fermato.
    func end() {
        guard isActive else { return }
        isActive = false
        task?.cancel()
        if pressedPlayPause {
            MediaKey.playPause()
            pressedPlayPause = false
        }
        guard let ducked else { return }
        self.ducked = nil
        // Se durante la dettatura hai cambiato tu il volume, resta il tuo.
        guard let now = SystemAudio.volume(ducked.device), abs(now - lastSet) < 0.02 else {
            Self.saveForRecovery(device: nil, volume: nil, target: nil)
            return
        }
        restoring = ducked
        task = Task { [weak self] in
            guard let self else { return }
            await self.ramp(ducked.device, to: ducked.volume)
            guard !Task.isCancelled else { return }
            self.restoring = nil
            Self.saveForRecovery(device: nil, volume: nil, target: nil)
        }
    }

    /// Voce chiusa a metà dettatura (crash, kill): all'avvio rimette il volume che aveva abbassato,
    /// ma solo se è ancora dove l'aveva lasciato (se l'hai cambiato tu, resta il tuo).
    static func recoverIfNeeded() {
        guard let uid = UserDefaults.standard.string(forKey: recoveryDevice),
              UserDefaults.standard.object(forKey: recoveryVolume) != nil else { return }
        let volume = UserDefaults.standard.float(forKey: recoveryVolume)
        let target = UserDefaults.standard.object(forKey: recoveryTarget) as? Float ?? 0   // versioni precedenti: sempre zero
        if let device = SystemAudio.device(uid: uid), let now = SystemAudio.volume(device), abs(now - target) < 0.02 {
            SystemAudio.setVolume(device, volume)
            log.info("volume ripristinato dopo una chiusura inattesa: \(volume)")
        }
        saveForRecovery(device: nil, volume: nil, target: nil)
    }

    // MARK: - Dettagli

    /// App che si registrano nei controlli "In riproduzione" di macOS e rispondono al tasto Play/Pausa.
    /// I browser suonano da processi helper ("com.google.Chrome.helper", "com.apple.WebKit.GPU"): basta il prefisso.
    nonisolated static let mediaApps = [
        "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX", "com.apple.Safari",
        "com.apple.WebKit", "com.google.Chrome", "company.thebrowser", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.spotify.client",
        "com.tidal.desktop", "com.deezer", "com.amazon.music", "org.videolan.vlc", "com.colliderli.iina",
    ]

    nonisolated static func isMediaApp(_ bundleID: String) -> Bool {
        mediaApps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// Dissolvenza dal volume attuale a `target` in `fade`, a piccoli passi.
    private func ramp(_ device: AudioObjectID, to target: Float32) async {
        let start = lastSet
        let steps = 12
        for i in 1...steps {
            try? await Task.sleep(for: Self.fade / steps)
            if Task.isCancelled { return }
            lastSet = start + (target - start) * Float32(i) / Float32(steps)
            SystemAudio.setVolume(device, lastSet)
        }
    }

    private static let recoveryDevice = "mediaPause.device"
    private static let recoveryVolume = "mediaPause.volume"
    private static let recoveryTarget = "mediaPause.target"

    private static func saveForRecovery(device: AudioObjectID?, volume: Float32?, target: Float32?) {
        if let device, let volume, let target, let uid = SystemAudio.uid(device) {
            UserDefaults.standard.set(uid, forKey: recoveryDevice)
            UserDefaults.standard.set(volume, forKey: recoveryVolume)
            UserDefaults.standard.set(target, forKey: recoveryTarget)
        } else {
            for key in [recoveryDevice, recoveryVolume, recoveryTarget] { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

/// Il tasto Play/Pausa della tastiera, simulato: va all'app "In riproduzione".
enum MediaKey {
    @MainActor static func playPause() {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (Int(NX_KEYTYPE_PLAY) << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Core Audio

/// Le poche proprietà Core Audio che servono: chi sta suonando e il volume del dispositivo di uscita.
enum SystemAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static var defaultOutput: AudioObjectID? {
        let id: AudioObjectID = get(system, kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        return id == 0 ? nil : id
    }

    /// L'oggetto Core Audio di un processo (serve a escluderlo da un tap), se macOS lo conosce.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Bundle ID dei processi che in questo momento mandano audio a un'uscita (escluso Voce).
    static func playingBundleIDs() -> Set<String> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        let me = getpid()
        var out = Set<String>()
        for process in processes {
            let running: UInt32 = get(process, kAudioProcessPropertyIsRunningOutput) ?? 0
            let pid: pid_t = get(process, kAudioProcessPropertyPID) ?? 0
            guard running != 0, pid != me else { continue }
            let bundleID = string(process, kAudioProcessPropertyBundleID) ?? ""
            out.insert(bundleID.isEmpty ? "pid \(pid)" : bundleID)   // es. afplay, senza bundle
        }
        return out
    }

    static func canSetVolume(_ device: AudioObjectID) -> Bool {
        var address = volumeAddress
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func volume(_ device: AudioObjectID) -> Float32? {
        get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    static func setVolume(_ device: AudioObjectID, _ value: Float32) {
        var address = volumeAddress
        var v = min(1, max(0, value))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    /// Il nome da mostrare di un dispositivo ("MacBook Pro Speakers", "AirPods di Luigi").
    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
