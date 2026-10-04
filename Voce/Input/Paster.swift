import AppKit
import Carbon.HIToolbox

/// Inserimento del testo (§7): clipboard + ⌘V sintetico + ripristino completo della clipboard.
@MainActor enum Paster {
    /// Marcatore per gli eventi sintetici di Voce, così il tap dei tasti li ignora.
    static let syntheticMarker: Int64 = 0x564F4345   // "VOCE"

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let source = CGEventSource(stateID: .combinedSessionState)

    /// Incolla `text` nel campo attivo con un solo ⌘V, a capo compresi: terminali, shell e agenti da riga di comando
    /// (Claude Code, Codex…) ricevono gli incolla come *bracketed paste* e non eseguono né inviano le righe intermedie.
    /// Simulare ⇧↩ non funziona ovunque: il Terminale di macOS lo tratta come ↩ e invierebbe il messaggio a metà.
    /// Ritorna appena il testo è stato incollato; il ripristino della clipboard avviene dopo `restoreAfterMs`.
    static func insert(_ text: String, pressReturn: Bool = false, restoreAfterMs: Int) async {
        flushPendingRestore()
        let saved = snapshot()
        let written = write(text)
        key(Keys.code(for: "v", or: kVK_ANSI_V), flags: .maskCommand)
        if pressReturn {
            try? await Task.sleep(for: .milliseconds(60))
            key(kVK_Return)
        }
        let id = UUID()
        pending = (id, saved, written)
        Task {
            try? await Task.sleep(for: .milliseconds(restoreAfterMs))
            if pending?.id == id { flushPendingRestore() }
        }
    }

    private static var pending: (id: UUID, snapshot: Snapshot, changeCount: Int)?

    /// Ripristina subito la clipboard in sospeso (anche quando parte una nuova dettatura prima dello scadere).
    private static func flushPendingRestore() {
        guard let p = pending else { return }
        pending = nil
        // Se nel frattempo l'utente ha copiato altro, non si tocca niente.
        if NSPasteboard.general.changeCount == p.changeCount { restore(p.snapshot) }
    }

    /// Command Mode: legge la selezione con ⌘C sintetico e ripristina la clipboard. `nil` se non c'è selezione.
    static func copySelection() async -> String? {
        flushPendingRestore()
        // Senza selezione VS Code, Cursor, JetBrains, Sublime e Zed copiano la riga intera: il comando la riscriverebbe
        // e la incollerebbe di nuovo. Prima si chiede all'Accessibilità, poi si guarda cosa ha copiato l'app.
        if focusedSelectionIsEmpty() { return nil }
        let pb = NSPasteboard.general
        let saved = snapshot()
        let before = pb.changeCount
        key(Keys.code(for: "c", or: kVK_ANSI_C), flags: .maskCommand)
        var text: String?
        for _ in 0..<25 {   // fino a ~500 ms
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before {
                text = isEmptySelectionCopy(pb) ? nil : pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { restore(saved) }
        return text
    }

    /// L'Accessibilità dice che nel campo attivo c'è solo il cursore. `false` se l'app non lo sa dire (Electron senza
    /// accessibilità, terminali…): in quel caso decide `isEmptySelectionCopy`.
    private static func focusedSelectionIsEmpty() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)   // un'app bloccata non deve fermare Voce
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var rangeValue: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &range), range.length == 0 else { return false }
        // Se l'app espone anche il testo selezionato, deve essere vuoto pure lui (alcune aggiornano solo uno dei due).
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let text = selected as? String, !text.isEmpty { return false }
        return true
    }

    /// VS Code e i suoi derivati (Cursor, Windsurf, VSCodium) segnano la riga copiata senza selezione con
    /// `"isFromEmptySelection":true`, dentro i dati personalizzati di Chromium (stringhe UTF-16) o in un tipo proprio.
    static func isEmptySelectionCopy(_ pb: NSPasteboard) -> Bool {
        let marker = #""isFromEmptySelection":true"#
        for type in pb.types ?? [] where type.rawValue.contains("chromium") || type.rawValue.contains("vscode") {
            guard let data = pb.data(forType: type) else { continue }
            if String(decoding: data, as: UTF8.self).contains(marker) { return true }
            let bytes = [UInt8](data)
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            if String(decoding: units, as: UTF16.self).contains(marker) { return true }
        }
        return false
    }

    // MARK: - Clipboard

    private struct Snapshot { let items: [[NSPasteboard.PasteboardType: Data]] }

    /// Tutti gli item con tutti i tipi, non solo le stringhe.
    private static func snapshot() -> Snapshot {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return Snapshot(items: items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        })
    }

    private static func restore(_ s: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !s.items.isEmpty else { return }
        pb.writeObjects(s.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        })
    }

    /// Scrive il testo marcato come transient (i clipboard manager lo ignorano). Restituisce il changeCount risultante.
    private static func write(_ text: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        pb.writeObjects([item])
        return pb.changeCount
    }

    // MARK: - Tastiera

    private static func key(_ code: Int, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
}
