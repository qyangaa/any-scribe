// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "any-scribe",
    platforms: [
        .macOS(.v13) // ScreenCaptureKit system-audio capture requires macOS 13+
    ],
    products: [
        .executable(name: "scribe", targets: ["scribe"]),
        .executable(name: "AnyScribe", targets: ["AnyScribe"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        // Shared logic: capture, pipeline, whisper, transcript, config, Recorder.
        .target(
            name: "ScribeCore"
        ),
        // CLI front-end.
        .executableTarget(
            name: "scribe",
            dependencies: [
                "ScribeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        // Menu-bar app front-end.
        .executableTarget(
            name: "AnyScribe",
            dependencies: [
                "ScribeCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ]
        )
    ]
)
