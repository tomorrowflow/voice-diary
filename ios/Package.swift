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
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.5.0"),
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
