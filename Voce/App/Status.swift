import SwiftUI

extension Controller {
    /// Stato riassuntivo mostrato dall'icona di menu bar, dalla sidebar e dalla Panoramica.
    var status: Status {
        if isRecording { return .recording }
        if isProcessing { return .processing }
        switch modelState {
        case .loading(let p): return .loading(p)
        case .failed(let e): return .failed(e)
        case .ready:
            guard permissionsGranted else { return .permissions }
            guard hotkeyActive else { return .hotkeyInactive }
            return .ready(Prefs.trigger.label)
        }
    }

    enum Status: Equatable {
        case loading(Double), failed(String), permissions, hotkeyInactive, ready(String), recording, processing

        var menuState: Brand.MenuState {
            switch self {
            case .loading: return .loading
            case .failed, .permissions, .hotkeyInactive: return .attention
            case .ready: return .ready
            case .recording: return .recording
            case .processing: return .processing
            }
        }
        var needsAttention: Bool { menuState == .attention }
        var tint: Color {
            switch self {
            case .loading: return .blue
            case .failed, .permissions, .hotkeyInactive: return .orange
            case .ready: return .green
            case .recording: return .red
            case .processing: return .purple
            }
        }
        var short: String {
            switch self {
            case .loading: return L("Preparazione…")
            case .failed: return L("Errore del modello")
            case .permissions: return L("Mancano permessi")
            case .hotkeyInactive: return L("Tasto non attivo")
            case .ready: return L("Pronto")
            case .recording: return L("In ascolto")
            case .processing: return L("Trascrivo…")
            }
        }
        var long: String {
            switch self {
            case .loading(let p): return p > 0 ? L("Preparazione del modello… %ld%%", Int(p * 100)) : L("Preparazione del modello…")
            case .failed(let e): return L("Errore del modello: %@", e)
            case .permissions: return L("Mancano dei permessi")
            case .hotkeyInactive: return L("Tasto di dettatura non attivo")
            case .ready(let key): return L("Pronto · tieni premuto %@", key)
            case .recording: return L("In ascolto…")
            case .processing: return L("Trascrivo…")
            }
        }
    }
}
