import AppKit
import AVFoundation

// MARK: - Permessi

enum Permissions {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var allGranted: Bool { microphone && Hotkey.hasAccessibility && Hotkey.hasInputMonitoring }
    static var inputDeviceName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
