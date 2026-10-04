// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voce",
    defaultLocalization: "it",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Unica dipendenza (§9.2). Il trait NemoTextProcessing (ITN/TTS) non serve: lo disattiviamo.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Voce",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Voce",
            exclude: ["Info.plist", "Resources"]   // risorse copiate da scripts/build.sh
        ),
        .testTarget(
            name: "VoceTests",
            dependencies: ["Voce"],
            path: "Tests"
        ),
    ]
)
