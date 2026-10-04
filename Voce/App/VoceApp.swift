import AppKit
import SwiftUI

// MARK: - Entry point: app menu bar oppure CLI (`Voce transcribe …`, usata da tools/eval.py)

@main enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "transcribe" {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var code: Int32 = 0
            Task.detached {
                code = await CLI.run(Array(args.dropFirst()))
                done.signal()
            }
            done.wait()
            exit(code)
        }
        if args.first == "meeting" {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var code: Int32 = 0
            Task.detached {
                code = await CLI.meeting(Array(args.dropFirst()))
                done.signal()
            }
            done.wait()
            exit(code)
        }
        if args.first == "snapshot" {
            MainActor.assumeIsolated { Snapshot.run(Array(args.dropFirst())) }
            exit(0)
        }
        VoceApp.main()
    }
}

struct VoceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = Controller.shared
    @ObservedObject private var meeting = MeetingRecorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            // Durante una riunione l'icona resta rossa anche se la dettatura è pronta, e accanto corre il tempo.
            HStack(spacing: 4) {
                Image(nsImage: Brand.menuIcon(meeting.isRecording ? .recording : controller.status.menuState))
                if meeting.isRecording { Text(Meeting.clock(Double(meeting.seconds))).monospacedDigit() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Controller.shared.launch() }
    }

    /// La registrazione di una riunione si salva anche se esci: si potrà elaborare al prossimo avvio.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MeetingRecorder.shared.stopForQuit() }
    }

    /// Doppio clic su Voce.app (Finder, Spotlight, Launchpad) mentre è già in esecuzione: apri la finestra.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Windows.show() }
        return true
    }
}

struct MenuContent: View {
    @ObservedObject var controller: Controller
    @ObservedObject private var meeting = MeetingRecorder.shared
    @AppStorage(Prefs.appLanguage) private var language   // ridisegna il menu quando cambia la lingua

    var body: some View {
        Text(controller.status.long)
        if controller.status.needsAttention {
            Button(L("Risolvi…")) { Windows.show(.overview) }
        }
        if let last = controller.lastText {
            Divider()
            Text(L("Ultima: “%@”", String(last.replacingOccurrences(of: "\n", with: " ").prefix(48)) + (last.count > 48 ? "…" : "")))
            Button(L("Re-incolla") + "  ⌃⌥V") { controller.repaste() }
            Button(L("Copia")) { copy(last) }
        }
        Divider()
        if meeting.isRecording {
            Button(L("Ferma la riunione") + " (\(Meeting.clock(Double(meeting.seconds))))") {
                Navigation.shared.meetingID = meeting.stop()
                Windows.show(.meetings)
            }
        } else {
            Button(L("Registra una riunione")) {
                Navigation.shared.meetingID = nil
                Windows.show(.meetings)
                meeting.start()
            }
        }
        Divider()
        Button(L("Apri Voce…")) { Windows.show(.overview) }
        Button(L("Riunioni…")) { Windows.show(.meetings) }
        Button(L("Cronologia…")) { Windows.show(.history) }
        Button(L("Dizionario…")) { Windows.show(.dictionary) }.keyboardShortcut("d")
        Button(L("Impostazioni…")) { Windows.show(.general) }.keyboardShortcut(",")
        Divider()
        Button(L("Esci da Voce")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
