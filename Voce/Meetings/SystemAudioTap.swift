import AVFoundation
import CoreAudio

/// L'audio che esce dal Mac (voci degli altri in Meet, Zoom, Teams, video…) catturato con un *process tap* di Core Audio
/// (macOS 14.2+): un tap globale mono, esclusa Voce, dentro un dispositivo aggregato privato da cui si leggono i buffer.
/// Non serve il permesso Registrazione schermo, ma «Registrazione audio di sistema» (si chiede alla prima registrazione).
///
/// Il tap vede l'audio *prima* del volume: abbassare il volume del Mac non cambia ciò che si registra.
@MainActor final class SystemAudioTap {
    typealias Handler = @Sendable (_ samples: [Float], _ hostTime: UInt64) -> Void

    enum TapError: LocalizedError {
        case coreAudio(String, OSStatus), noOutput
        var errorDescription: String? {
            switch self {
            case .coreAudio(let what, let status): return L("Core Audio: %@ (errore %ld)", what, Int(status))
            case .noOutput: return L("Nessuna uscita audio disponibile.")
            }
        }
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "it.dimarcantonio.voce.system-tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private(set) var isRunning = false

    init(handler: @escaping Handler) { self.handler = handler }

    func start() throws {
        try open()
        isRunning = true
        // Cuffie collegate o scollegate a metà riunione: il dispositivo di riferimento cambia, il tap riparte.
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    func stop() {
        if let outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
            self.outputListener = nil
        }
        close()
        isRunning = false
    }

    private func outputChanged() {
        guard isRunning else { return }
        close()
        do { try open() } catch { log.error("system tap: riavvio dopo il cambio di uscita fallito: \(error.localizedDescription)") }
    }

    // MARK: Core Audio

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func open() throws {
        guard let output = SystemAudio.defaultOutput, let outputUID = SystemAudio.uid(output) else { throw TapError.noOutput }

        let me = SystemAudio.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: me)
        description.uuid = UUID()
        description.name = "Voce"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "creazione del tap")

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "formato del tap")
        guard let format = AVAudioFormat(streamDescription: &asbd), let converter = PCMConverter(from: format) else {
            close()
            throw TapError.coreAudio("formato audio non supportato", kAudioHardwareUnsupportedOperationError)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voce riunione",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        do {
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "dispositivo aggregato")
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue,
                                                              Self.ioBlock(format: format, converter: converter, handler: handler)),
                           "lettura dell'audio")
            // È qui, non alla creazione del tap, che macOS chiede il permesso alla prima volta.
            try Self.check(AudioDeviceStart(aggregateID, procID), "avvio")
        } catch {
            close()
            throw error
        }
    }

    /// Il callback gira sul thread audio: va creato fuori dall'isolamento di `@MainActor`, altrimenti Swift ne verifica
    /// l'esecuzione sul thread principale e l'app si ferma.
    private nonisolated static func ioBlock(format: AVAudioFormat, converter: PCMConverter, handler: @escaping Handler) -> AudioDeviceIOBlock {
        { _, input, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { handler(samples, inputTime.pointee.mHostTime) }
        }
    }

    private func close() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.coreAudio(what, status) }
    }
}
