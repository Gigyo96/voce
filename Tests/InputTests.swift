import Carbon.HIToolbox
import CoreGraphics
import AppKit
import Foundation
import Testing
@testable import Voce

// Tasto di dettatura: macchina a stati dell'event tap e scorciatoie registrate.

@Suite @MainActor struct HotkeyTests {
    /// ⌘ destro premuto (0x10 = bit del lato destro) o rilasciato.
    private func rightCommand(_ down: Bool) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(54), keyDown: down)!
        e.type = .flagsChanged
        e.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10) : []
        return e
    }

    @Test func spaceWhileHoldingSwitchesToHandsFree() {
        let hk = Hotkey()
        var events: [String] = []
        hk.onStart = { events.append("start \($0)") }
        hk.onModeChange = { events.append("mode \($0)") }
        hk.onStop = { events.append("stop") }
        hk.onCancel = { events.append("cancel") }

        _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
        let space = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(49), keyDown: true)!
        #expect(hk.handle(type: .keyDown, event: space))          // lo Spazio non arriva all'app
        _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        #expect(events == ["start pushToTalk", "mode handsFree"])  // il rilascio non chiude
        _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
        _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        #expect(events.last == "stop")
    }

    @Test func doubleTapOnlyWhenChosen() {
        let hk = Hotkey()
        var starts: [String] = []
        hk.onStart = { starts.append("\($0)") }
        for _ in 0..<2 {
            _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
            _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        }
        #expect(!starts.contains("handsFree"))   // default .space: il doppio tocco resta a Siri
    }

    @Test func functionKeyTriggerIsSwallowedAndHeld() {
        let hk = Hotkey()
        hk.trigger = Hotkey.Trigger(kVK_F5)
        var events: [String] = []
        hk.onStart = { events.append("start \($0)") }
        hk.onStop = { events.append("stop") }
        let f5 = { (down: Bool) in CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_F5), keyDown: down)! }
        #expect(hk.handle(type: .keyDown, event: f5(true)))
        #expect(hk.handle(type: .keyDown, event: f5(true)))      // autoripetizione: nessun secondo start
        Thread.sleep(forTimeInterval: Hotkey.minHold)
        #expect(hk.handle(type: .keyUp, event: f5(false)))
        #expect(events == ["start pushToTalk", "stop"])
    }

    @Test func recordsModifierOnReleaseAndKeyOnPress() {
        let hk = Hotkey()
        var got: Hotkey.Trigger?
        hk.record { got = $0 }
        _ = hk.handle(type: .flagsChanged, event: rightCommand(true))
        #expect(got == nil)
        _ = hk.handle(type: .flagsChanged, event: rightCommand(false))
        #expect(got == .rightCommand)

        hk.record { got = $0 }
        let space = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: true)!
        space.flags = [.maskControl, .maskAlternate]
        #expect(hk.handle(type: .keyDown, event: space))
        #expect(got == Hotkey.Trigger(kVK_Space, [.maskControl, .maskAlternate]))
    }
}

@Suite struct TriggerTests {
    typealias T = Hotkey.Trigger

    @Test func prefRoundTripKeepsLegacyNames() {
        #expect(T(rawValue: "rightCommand") == .rightCommand)
        #expect(T.rightOption.rawValue == "rightOption")
        let combo = T(kVK_Space, [.maskControl, .maskAlternate, .maskSecondaryFn])   // Fn non conta
        #expect(T(rawValue: combo.rawValue) == combo)
        #expect(combo.flags == [.maskControl, .maskAlternate])
        #expect(T(rawValue: "garbage") == nil)
    }

    @Test func commandModifierNeverClashesWithTheTrigger() {
        #expect(T.rightCommand.commandModifier == .maskShift)
        #expect(T.fn.commandModifier == .maskCommand)
        #expect(T(kVK_F5).commandModifier == .maskCommand)
        #expect(T(kVK_Space, [.maskCommand, .maskShift]).commandModifier == .maskAlternate)
    }

    @Test func rejectsKeysThatType() {
        #expect(T(kVK_ANSI_A).problem != nil)
        #expect(T(kVK_Space, .maskAlternate).problem != nil)    // ⌥Spazio scrive uno spazio unificatore
        #expect(T(kVK_CapsLock).problem != nil)
        #expect(T(kVK_Space, [.maskControl, .maskAlternate]).problem == nil)
        #expect(T(kVK_F13).problem == nil)
        #expect(T(0xB0).problem == nil)                          // 🎤
        #expect(T(kVK_Option).problem == nil)
    }

    @Test func modifierStateWithAndWithoutSideBits() {
        let rightCmd = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        #expect(Keys.isPressed(kVK_RightCommand, rightCmd))
        #expect(!Keys.isPressed(kVK_Command, rightCmd))
        // Tastiera che non imposta i bit del lato: vale il flag generico.
        #expect(Keys.isPressed(kVK_RightOption, .maskAlternate))
        #expect(!Keys.isPressed(kVK_RightOption, []))
    }
}

@Suite @MainActor struct PasterTests {
    /// Appunti privati, per non toccare quelli dell'utente.
    private func pasteboard(_ type: String, _ data: Data) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("voce-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.declareTypes([.string, .init(type)], owner: nil)
        pb.setString("    let x = 1", forType: .string)
        pb.setData(data, forType: .init(type))
        return pb
    }

    @Test func recognisesTheLineVSCodeCopiesWithoutSelection() {
        let json = #"{"version":1,"isFromEmptySelection":true,"multicursorText":null,"mode":"swift"}"#
        // Chromium: tipi personalizzati in un blob con stringhe UTF-16 (little endian), preceduti da lunghezze.
        var blob = Data([2, 0, 0, 0])
        blob += json.data(using: .utf16LittleEndian)!
        #expect(Paster.isEmptySelectionCopy(pasteboard("org.chromium.web-custom-data", blob)))
        #expect(Paster.isEmptySelectionCopy(pasteboard("vscode-editor-data", Data(json.utf8))))
        let selected = json.replacingOccurrences(of: "true", with: "false")
        #expect(!Paster.isEmptySelectionCopy(pasteboard("org.chromium.web-custom-data", selected.data(using: .utf16LittleEndian)!)))
        #expect(!Paster.isEmptySelectionCopy(pasteboard("public.rtf", Data(json.utf8))))
    }
}
