// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscriptEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "TranscriptEngine",
            targets: ["TranscriptEngine"]
        ),
    ],
    targets: [
        .target(
            name: "TranscriptEngine",
            path: "Sources"
        ),
        .testTarget(
            name: "TranscriptEngineTests",
            dependencies: ["TranscriptEngine"],
            path: "Tests"
        ),
    ]
)
