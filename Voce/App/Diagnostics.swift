import Foundation
import os

private let logger = Logger(subsystem: "it.dimarcantonio.voce", category: "app")

/// Log diagnostico (pubblico, livello notice): `log show --predicate 'subsystem == "it.dimarcantonio.voce"' --last 10m`
enum log {
    static func info(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func debug(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
}

// MARK: - Diagnostica

/// Se il thread principale non risponde per 3 s salva un campionamento in `~/.voce/hang-<ts>.txt` (una volta per avvio):
/// un'interfaccia bloccata non lascia crash report, così resta la traccia di dove era fermo.
enum HangDetector {
    static func start() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                let pong = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { pong.signal() }
                guard pong.wait(timeout: .now() + 3) == .timedOut else { continue }
                try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
                let out = Paths.dir.appending(path: "hang-\(History.timestamp()).txt")
                log.error("interfaccia bloccata da 3 s: campionamento in \(out.path)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                p.arguments = ["\(getpid())", "2", "-file", out.path]
                try? p.run()
                p.waitUntilExit()
                return
            }
        }
    }
}
