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
        .library(
            name: "SampleChat",
            targets: ["SampleChat"]
        ),
    ],
    targets: [
        .target(
            name: "TranscriptEngine",
            path: "Sources"
        ),
        .target(
            name: "SampleChat",
            dependencies: ["TranscriptEngine"],
            path: "Examples/SampleChat"
        ),
        .testTarget(
            name: "TranscriptEngineTests",
            dependencies: ["TranscriptEngine"],
            path: "Tests",
            resources: [.process("Resources")]
        ),
    ]
)
