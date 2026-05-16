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
            swiftSettings: [
                // Avoid Swift 6 strict-concurrency friction with the many
                // CoreAudio / ScreenCaptureKit C callbacks.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
