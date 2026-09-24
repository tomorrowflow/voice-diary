// swift-tools-version: 6.0
//
// SwiftPM manifest for the Voice Diary iOS app.
//
// The Xcode app target consumes this package via XcodeGen's `packages:` block
// (see project.yml). Keeping a Package.swift here also lets Swift code be
// split into a static library + tests if we need that later.

import PackageDescription

let package = Package(
    name: "VoiceDiary",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "VoiceDiaryCore", targets: ["VoiceDiaryCore"]),
    ],
    dependencies: [
        // 0.14.x adds the streaming Parakeet pipeline (`StreamingEouAsrManager`,
        // EN-only `parakeet-realtime-eou-120m` model) used by the wake-word
        // detector. The batch v3 multilingual path we already use for upload
        // transcription is preserved.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.14.4"),
    ],
    targets: [
        .target(
            name: "VoiceDiaryCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources",
            exclude: ["App"]
        ),
    ]
)
