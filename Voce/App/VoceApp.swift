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

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(nsImage: Brand.menuIcon(controller.status.menuState))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Controller.shared.launch() }
    }

    /// Doppio clic su Voce.app (Finder, Spotlight, Launchpad) mentre è già in esecuzione: apri la finestra.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Windows.show() }
        return true
    }
}

struct MenuContent: View {
    @ObservedObject var controller: Controller

    var body: some View {
        Text(controller.status.long)
        if controller.status.needsAttention {
            Button("Risolvi…") { Windows.show(.overview) }
        }
        if let last = controller.lastText {
            Divider()
            Text("Ultima: “\(last.replacingOccurrences(of: "\n", with: " ").prefix(48))\(last.count > 48 ? "…" : "")”")
            Button("Re-incolla  ⌃⌥V") { controller.repaste() }
            Button("Copia") { copy(last) }
        }
        Divider()
        Button("Apri Voce…") { Windows.show(.overview) }
        Button("Cronologia…") { Windows.show(.history) }
        Button("Dizionario…") { Windows.show(.dictionary) }.keyboardShortcut("d")
        Button("Impostazioni…") { Windows.show(.general) }.keyboardShortcut(",")
        Divider()
        Button("Esci da Voce") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
