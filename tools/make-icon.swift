#!/usr/bin/env swift
// Disegna l'icona di Voce e genera Voce/AppIcon.icns (iconutil).
//
//   swift tools/make-icon.swift            # dalla radice del progetto
//
// Squircle con gradiente corallo → viola e cinque barre bianche: la stessa forma dell'icona di menu bar
// (Voce/Brand.swift), così Dock, Finder e barra dei menu si riconoscono come la stessa app.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appending(path: "Voce.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Altezze relative delle barre (stesse di `Brand.barHeights`).
let heights: [CGFloat] = [0.38, 0.72, 1.0, 0.58, 0.30]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Griglia delle icone macOS: corpo 824/1024 centrato, raggio ~22,4%.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.2237
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Ombra morbida sotto il corpo.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradiente diagonale.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [NSColor(srgbRed: 1.00, green: 0.45, blue: 0.36, alpha: 1).cgColor,   // corallo
                  NSColor(srgbRed: 0.93, green: 0.27, blue: 0.55, alpha: 1).cgColor,   // magenta
                  NSColor(srgbRed: 0.42, green: 0.25, blue: 0.96, alpha: 1).cgColor]   // viola
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                              locations: [0, 0.48, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Luce dall'alto.
    let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // Barre.
    let barW = body.width * 0.085
    let gap = body.width * 0.062
    let maxH = body.height * 0.50
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.018,
                  color: NSColor(srgbRed: 0.25, green: 0.05, blue: 0.35, alpha: 0.35).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    for h in heights {
        let bh = max(barW, maxH * h)
        let bar = CGRect(x: x, y: body.midY - bh / 2, width: barW, height: bh)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        x += barW + gap
    }
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: root.appending(path: "build/AppIcon-1024.png"), options: .atomic)

let out = root.appending(path: "Voce/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil fallito") }
print("✓ \(out.path)")
