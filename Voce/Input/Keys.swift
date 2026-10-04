import Carbon.HIToolbox
import CoreGraphics

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
