import AppKit
import Carbon.HIToolbox

/// Inserimento del testo (§7): clipboard + ⌘V sintetico + ripristino completo della clipboard.
@MainActor enum Paster {
    /// Marcatore per gli eventi sintetici di Voce, così il tap dei tasti li ignora.
    static let syntheticMarker: Int64 = 0x564F4345   // "VOCE"

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let source = CGEventSource(stateID: .combinedSessionState)

    /// Incolla `text` nel campo attivo. Con `newlineKey == "shift+return"` gli a capo diventano ⇧↩ (terminali con agent).
    /// Ritorna appena il testo è stato incollato; il ripristino della clipboard avviene dopo `restoreAfterMs`.
    static func insert(_ text: String, newlineKey: String = "return", pressReturn: Bool = false, restoreAfterMs: Int) async {
        flushPendingRestore()
        let saved = snapshot()
        let segments = newlineKey == "shift+return" ? text.components(separatedBy: "\n") : [text]
        var written = 0
        for (i, segment) in segments.enumerated() {
            if i > 0 {
                key(kVK_Return, flags: .maskShift)
                try? await Task.sleep(for: .milliseconds(15))
            }
            guard !segment.isEmpty else { continue }
            written = write(segment)
            key(Keys.code(for: "v", or: kVK_ANSI_V), flags: .maskCommand)
            // L'app destinataria legge la clipboard in modo asincrono: tra un segmento e l'altro serve un attimo.
            if i < segments.count - 1 { try? await Task.sleep(for: .milliseconds(60)) }
        }
        if pressReturn {
            try? await Task.sleep(for: .milliseconds(60))
            key(kVK_Return)
        }
        guard written != 0 else { return }
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
        let pb = NSPasteboard.general
        let saved = snapshot()
        let before = pb.changeCount
        key(Keys.code(for: "c", or: kVK_ANSI_C), flags: .maskCommand)
        var text: String?
        for _ in 0..<25 {   // fino a ~500 ms
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before { text = pb.string(forType: .string); break }
        }
        if pb.changeCount != before { restore(saved) }
        return text
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
    @discardableResult
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
