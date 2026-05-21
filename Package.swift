// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ghostie",
    platforms: [
        // macOS 15+ required for ScreenCaptureKit native microphone capture
        // (SCStreamOutputType.microphone). Host here is macOS 26.
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "ghostie",
            path: "Sources/ghostie",
            resources: [
                // Bundled assets shipped in the SwiftPM resource bundle. The
                // built .app picks this up automatically; `swift run` /
                // `swift build` get it via `Bundle.module`.
                .process("Resources")
            ],
            swiftSettings: [
                // Avoid Swift 6 strict-concurrency friction with the many
                // CoreAudio / ScreenCaptureKit C callbacks.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
