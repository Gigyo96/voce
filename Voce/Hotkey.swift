import AppKit
import Carbon.HIToolbox
import IOKit.hid
import os

private let logger = Logger(subsystem: "it.dimarcantonio.voce", category: "app")

/// Log diagnostico (pubblico, livello notice): `log show --predicate 'subsystem == "it.dimarcantonio.voce"' --last 10m`
enum log {
    static func info(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func debug(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
}

/// Hotkey globali via `CGEventTap` (§4.3).
///
/// - Hold del tasto scelto → push-to-talk: `⌘` destro (default), un preset o qualunque tasto/combinazione registrata
///   (`Trigger`: modificatori sinistri/destri, Fn, F1–F20, 🎤, Menu, ⌃⌥Spazio…), su qualunque tastiera e layout.
/// - Hands-free (`HandsFree`): tasto + Spazio (default) o doppio tap; un tap successivo chiude, `Esc` annulla.
///   Il doppio tap di ⌘ è anche la scorciatoia predefinita di Siri: per questo non è il default.
/// - Tasto + ⌘ (con ⌘ destro: + ⇧), anche premuto durante l'hold → Command Mode.
/// - `⌃⌥V` → re-incolla l'ultima dettatura.
/// - Un qualunque altro tasto premuto durante l'hold (Fn+freccia, ⌥+ò per "@"…) annulla: era una scorciatoia.
@MainActor final class Hotkey {
    /// Tasto di dettatura: un tasto qualsiasi (modificatore sinistro/destro, Fn, F1–F20, 🎤, Menu…) più eventuali
    /// modificatori richiesti. Si confronta per keyCode, quindi vale per ogni layout e ogni tastiera (Apple, PC, esterne).
    /// Preferenza `hotkey`: i nomi storici dei preset oppure `"<keyCode>:<modificatori>"`.
    struct Trigger: Hashable, Sendable {
        let keyCode: Int
        let mods: UInt64

        init(_ keyCode: Int, _ mods: CGEventFlags = []) {
            self.keyCode = keyCode
            self.mods = mods.intersection(Keys.generic).rawValue
        }

        static let rightCommand = Trigger(kVK_RightCommand)
        static let rightOption = Trigger(kVK_RightOption)
        static let rightControl = Trigger(kVK_RightControl)
        static let fn = Trigger(kVK_Function)
        static let allCases = [rightCommand, rightOption, rightControl, fn]
        private static let names = ["rightCommand": rightCommand, "rightOption": rightOption,
                                    "rightControl": rightControl, "fn": fn]

        init?(rawValue: String) {
            if let t = Self.names[rawValue] { self = t; return }
            let parts = rawValue.split(separator: ":").compactMap { UInt64($0) }
            guard parts.count == 2, parts[0] < 0x10000 else { return nil }
            self.init(Int(parts[0]), CGEventFlags(rawValue: parts[1]))
        }
        var rawValue: String { Self.names.first { $0.value == self }?.key ?? "\(keyCode):\(mods)" }

        var flags: CGEventFlags { CGEventFlags(rawValue: mods) }
        var isModifierKey: Bool { Keys.modifier(keyCode) != nil }

        /// Modificatore che, insieme al tasto, attiva il Command Mode: ⌘, o il primo libero se ⌘ fa già parte del tasto.
        var commandModifier: CGEventFlags {
            let taken = flags.union(Keys.modifier(keyCode)?.flag ?? [])
            return [CGEventFlags.maskCommand, .maskShift, .maskAlternate, .maskControl].first { !taken.contains($0) } ?? .maskCommand
        }

        /// Perché non va bene come tasto di dettatura (`nil` se va bene).
        var problem: String? {
            if keyCode == kVK_CapsLock { return "Bloc Maiusc non si può tenere premuto: scegli un altro tasto." }
            if isModifierKey || Keys.bareAllowed(keyCode) { return nil }
            if flags.intersection([.maskCommand, .maskControl]).isEmpty {
                return "Questo tasto scrive un carattere: aggiungi ⌃ o ⌘, oppure usa un tasto funzione (F1–F20)."
            }
            return nil
        }

        @MainActor var keys: [String] { Keys.symbols(flags) + [Keys.label(keyCode)] }
        @MainActor var label: String { (Keys.symbols(flags).joined() + " " + Keys.label(keyCode)).trimmingCharacters(in: .whitespaces) }
        @MainActor var commandKeys: [String] { keys + Keys.symbols(commandModifier) }
    }

    enum HandsFree: String, CaseIterable, Sendable {
        case space, doubleTap, off
        @MainActor func keys(_ t: Trigger) -> [String] {
            switch self {
            case .space: return [t.label, "Spazio"]
            case .doubleTap: return [t.label, t.label]
            case .off: return []
            }
        }
    }

    enum Mode: Sendable { case pushToTalk, handsFree, command }

    var onStart: (Mode) -> Void = { _ in }
    var onModeChange: (Mode) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRepaste: () -> Void = {}
    var trigger: Trigger = .rightCommand
    var handsFree: HandsFree = .space

    static let minHold: TimeInterval = 0.25
    static let doubleTapWindow: TimeInterval = 0.40

    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private(set) var isInstalled = false

    private var session: Mode?
    private var downAt = Date.distantPast
    private var lastTapUp: Date?
    private var ignoreNextUp = false
    private var stopOnUp = false
    private var heldKey: Int?


    // MARK: - Installazione

    /// Crea il tap e lo sorveglia ogni 2 s: se mancano i permessi riprova, se i permessi cambiano
    /// (concessi o revocati mentre l'app gira) lo ricrea, se il sistema lo disabilita lo riabilita.
    func install() {
        installHIDFn()
        refresh()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private var watchdog: Timer?
    private var grantedAtInstall: (ax: Bool, listen: Bool)?
    private(set) var eventsSeen = 0

    private func refresh() {
        let now = (ax: Self.hasAccessibility, listen: Self.hasInputMonitoring)
        if let tap, let granted = grantedAtInstall, granted != now {
            log.info("permessi cambiati (ax \(now.ax), input \(now.listen)): ricreo il tap")
            uninstall(tap)
        }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.info("tap disabilitato dal sistema: lo riabilito")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard now.ax else { return }   // un tap attivo (che sopprime ⌃⌥V) richiede Accessibilità
        if tryInstall() {
            grantedAtInstall = now
            log.info("tap installato (ax \(now.ax), input \(now.listen), trigger \(self.trigger.rawValue))")
        } else {
            log.error("CGEvent.tapCreate fallito (ax \(now.ax), input \(now.listen))")
        }
    }

    private func uninstall(_ port: CFMachPort) {
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(port)
        runLoopSource = nil
        tap = nil
        isInstalled = false
    }

    private var runLoopSource: CFRunLoopSource?

    // MARK: - Fn via IOHIDManager

    /// Su macOS recenti il tasto 🌐 spesso non arriva agli event tap (il sistema lo consuma per emoji,
    /// dettatura o cambio sorgente). Lo leggiamo anche dall'HID: pagina Apple vendor, usage "Function".
    /// Serve solo Monitoraggio input. Le pressioni doppie (tap + HID) sono filtrate da `heldKey`.
    private var hid: IOHIDManager?

    private func installHIDFn() {
        guard hid == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboards: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, keyboards as CFArray)
        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            // 0xFF/0x03 = AppleVendorTopCase KeyboardFn · 0xFF01/0x03 = AppleVendorKeyboard Function
            guard usage == 0x03, page == 0xFF || page == 0xFF01 else { return }
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.hidFn(pressed: pressed) }
        }
        IOHIDManagerRegisterInputValueCallback(manager, callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log.info("IOHIDManager per Fn: \(result == kIOReturnSuccess ? "attivo" : "errore \(result)")")
        hid = manager
    }

    private func hidFn(pressed: Bool) {
        log.debug("HID Fn \(pressed ? "giù" : "su")")
        var flags = CGEventSource.flagsState(.combinedSessionState)
        if pressed { flags.insert(.maskSecondaryFn) } else { flags.remove(.maskSecondaryFn) }
        if recorder != nil { return recordEvent(.flagsChanged, kVK_Function, flags) }
        guard trigger.keyCode == kVK_Function else { return }
        if pressed {
            triggerDown(kVK_Function, flags)
        } else {
            triggerUp(kVK_Function)
        }
    }

    private func tryInstall() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { hotkey.handle(type: type, event: event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        runLoopSource = src
        tap = port
        isInstalled = true
        return true
    }

    // MARK: - Gestione eventi

    /// Restituisce `true` se l'evento va soppresso.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Paster.syntheticMarker { return false }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let mods = flags.intersection(Keys.generic)
        eventsSeen += 1
        if recorder != nil {
            recordEvent(type, keyCode, flags)
            return type == .keyDown
        }
        if type == .flagsChanged, keyCode == trigger.keyCode {
            log.debug("flagsChanged key \(keyCode) flags 0x\(String(flags.rawValue, radix: 16)) trigger \(self.trigger.rawValue)")
        }

        if type == .flagsChanged {
            if keyCode == trigger.keyCode {
                Keys.isPressed(keyCode, flags) ? triggerDown(keyCode, flags) : triggerUp(keyCode)
            } else if let held = heldKey, !mods.isSuperset(of: trigger.flags) {
                triggerUp(held)   // rilasciato un modificatore della combinazione
            } else if session == .pushToTalk, heldKey != nil, flags.contains(trigger.commandModifier) {
                session = .command
                onModeChange(.command)
            }
            return false
        }

        // Tasto non modificatore (F5, 🎤, ⌃⌥Spazio…): keyDown/keyUp fanno da pressione/rilascio e non arrivano all'app.
        if keyCode == trigger.keyCode, !trigger.isModifierKey {
            if type == .keyUp {
                guard heldKey == keyCode else { return false }
                triggerUp(keyCode)
                return true
            }
            if heldKey == keyCode { return true }   // autoripetizione
            if mods == trigger.flags || mods == trigger.flags.union(trigger.commandModifier) {
                triggerDown(keyCode, flags)
                return true
            }
        }
        if type == .keyUp { return false }

        // keyDown
        if mods == [.maskControl, .maskAlternate], keyCode == Keys.code(for: "v", or: kVK_ANSI_V) {
            onRepaste()
            return true
        }
        if keyCode == kVK_Escape, session != nil {
            cancel()
            return true
        }
        // Tasto + Spazio: si passa a mani libere; lo Spazio (e la sua ripetizione) non arriva all'app.
        if keyCode == kVK_Space, heldKey != nil, handsFree == .space, session == .pushToTalk || session == .handsFree {
            if session == .pushToTalk {
                session = .handsFree
                ignoreNextUp = true
                onModeChange(.handsFree)
            }
            return true
        }
        if heldKey != nil, session == .pushToTalk || session == .command {
            cancel()   // accordo: l'utente stava usando il tasto come modificatore
        }
        return false
    }

    private func triggerDown(_ keyCode: Int, _ flags: CGEventFlags) {
        guard heldKey == nil, flags.intersection(Keys.generic).isSuperset(of: trigger.flags) else { return }
        heldKey = keyCode
        let now = Date()
        if session == .handsFree {
            // Si chiude al rilascio, così il ⌘V sintetico non arriva mentre Fn è ancora premuto.
            stopOnUp = true
            return
        }
        if session != nil { return }
        if handsFree == .doubleTap, let last = lastTapUp, now.timeIntervalSince(last) < Self.doubleTapWindow {
            lastTapUp = nil
            ignoreNextUp = true
            session = .handsFree
            onStart(.handsFree)
            return
        }
        downAt = now
        session = flags.contains(trigger.commandModifier) ? .command : .pushToTalk
        onStart(session!)
    }

    private func triggerUp(_ keyCode: Int) {
        guard heldKey == keyCode else { return }
        heldKey = nil
        if stopOnUp {
            stopOnUp = false
            session = nil
            onStop()
            return
        }
        if ignoreNextUp { ignoreNextUp = false; return }
        guard session == .pushToTalk || session == .command else { return }
        let held = Date().timeIntervalSince(downAt)
        if held < Self.minHold {
            lastTapUp = session == .pushToTalk ? Date() : nil
            session = nil
            onCancel()
        } else {
            session = nil
            onStop()
        }
    }

    private func cancel() {
        let wasActive = session != nil
        session = nil
        stopOnUp = false
        lastTapUp = nil
        if heldKey != nil { ignoreNextUp = true }
        if wasActive { onCancel() }
    }

    /// Chiamato dall'app quando la dettatura termina per altre vie (es. durata massima raggiunta).
    func reset() {
        session = nil
        stopOnUp = false
        if heldKey != nil { ignoreNextUp = true }
    }

    // MARK: - Registrazione della scorciatoia

    private var recorder: ((Trigger?) -> Void)?
    private var candidate: Trigger?

    /// La prossima combinazione premuta viene passata a `done` invece di avviare la dettatura (`nil` = annullata con Esc).
    /// Un modificatore da solo si registra al rilascio, un tasto normale alla pressione.
    func record(_ done: @escaping (Trigger?) -> Void) {
        cancel()
        candidate = nil
        recorder = done
    }

    func stopRecording() { finishRecording(nil) }

    private func recordEvent(_ type: CGEventType, _ keyCode: Int, _ flags: CGEventFlags) {
        let mods = flags.intersection(Keys.generic)
        if type == .keyDown {
            finishRecording(keyCode == kVK_Escape && mods.isEmpty ? nil : Trigger(keyCode, mods))
        } else if type == .flagsChanged, let m = Keys.modifier(keyCode) {
            if Keys.isPressed(keyCode, flags) {
                candidate = Trigger(keyCode, mods.subtracting(m.flag))
            } else if mods.isEmpty, !flags.contains(.maskSecondaryFn), let c = candidate {
                finishRecording(c)
            }
        }
    }

    private func finishRecording(_ t: Trigger?) {
        let done = recorder
        recorder = nil
        candidate = nil
        done?(t)
    }

    // MARK: - Permessi

    nonisolated static var hasAccessibility: Bool { AXIsProcessTrusted() }
    nonisolated static var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }

    nonisolated static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    nonisolated static func requestInputMonitoring() { _ = CGRequestListenEventAccess() }
}

// MARK: - Tasti

/// Tutto ciò che dipende dalla tastiera fisica o dal layout attivo (italiano, US, Dvorak, AZERTY, cirillico…).
enum Keys {
    static let generic: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Bit "device dependent" del lato specifico, bit di entrambi i lati, flag generico.
    static func modifier(_ code: Int) -> (bit: UInt64, family: UInt64, flag: CGEventFlags)? {
        switch code {
        case kVK_Command: return (0x08, 0x18, .maskCommand)
        case kVK_RightCommand: return (0x10, 0x18, .maskCommand)
        case kVK_Shift: return (0x02, 0x06, .maskShift)
        case kVK_RightShift: return (0x04, 0x06, .maskShift)
        case kVK_Option: return (0x20, 0x60, .maskAlternate)
        case kVK_RightOption: return (0x40, 0x60, .maskAlternate)
        case kVK_Control: return (0x01, 0x2001, .maskControl)
        case kVK_RightControl: return (0x2000, 0x2001, .maskControl)
        case kVK_Function: return (0, 0, .maskSecondaryFn)
        default: return nil
        }
    }

    /// Stato del modificatore dopo un flagsChanged. Il bit del lato distingue destro da sinistro; alcune tastiere
    /// esterne e i remapper non lo impostano: in quel caso basta il flag generico.
    static func isPressed(_ code: Int, _ flags: CGEventFlags) -> Bool {
        guard let m = modifier(code), flags.contains(m.flag) else { return false }
        return flags.rawValue & m.bit != 0 || flags.rawValue & m.family == 0
    }

    static let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// Tasti utilizzabili senza modificatori: non scrivono nulla. 0xB0–0xB2 = 🎤 Dettatura, Spotlight, Non disturbare.
    static func bareAllowed(_ code: Int) -> Bool {
        fKeys.contains(code) || code == kVK_ContextualMenu || code == kVK_Help || code >= 0x80
    }

    static func symbols(_ f: CGEventFlags) -> [String] {
        [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { f.contains($0.0) }.map(\.1)
    }

    @MainActor static func label(_ code: Int) -> String {
        if let i = fKeys.firstIndex(of: code) { return "F\(i + 1)" }
        switch code {
        case kVK_Command: return "⌘ sinistro"
        case kVK_RightCommand: return "⌘ destro"
        case kVK_Shift: return "⇧ sinistro"
        case kVK_RightShift: return "⇧ destro"
        case kVK_Option: return "⌥ sinistro"
        case kVK_RightOption: return "⌥ destro"
        case kVK_Control: return "⌃ sinistro"
        case kVK_RightControl: return "⌃ destro"
        case kVK_Function: return "Fn 🌐"
        case kVK_CapsLock: return "⇪"
        case kVK_Space: return "Spazio"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Help: return "Help"
        case kVK_ContextualMenu: return "Menu"
        case 0xB0: return "🎤"
        case 0xB1: return "🔍"
        case 0xB2: return "🌙"
        default:
            let c = character(code)
            return c.isEmpty || c.unicodeScalars.contains(where: { $0.value < 0x20 }) ? "Tasto \(code)" : c.uppercased()
        }
    }

    /// Carattere prodotto da `code` nel layout attivo (con `cmd`, la tabella usata per le scorciatoie ⌘).
    @MainActor static func character(_ code: Int, cmd: Bool = false) -> String {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let layout = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap {
                TISGetInputSourceProperty($0.takeRetainedValue(), kTISPropertyUnicodeKeyLayoutData)
            }
        guard let layout else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buf in
            UCKeyTranslate(buf.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(code),
                           UInt16(kUCKeyActionDisplay), cmd ? UInt32(cmdKey >> 8) & 0xFF : 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : ""
    }

    /// keyCode che nel layout attivo dà `char` con ⌘ (⌘V su Dvorak non è il tasto 9). Default: posizione ANSI.
    @MainActor static func code(for char: String, or ansi: Int) -> Int {
        (0..<128).first { character($0, cmd: true) == char } ?? ansi
    }
}
