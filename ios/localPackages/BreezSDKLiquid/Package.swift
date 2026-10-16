// swift-tools-version:5.9
import PackageDescription

// BreezSDKLiquid — vendored Swift bindings for the Breez SDK Liquid, 0.12.4.
//
// Breez retired the Liquid SDK and deleted github.com/breez/breez-sdk-liquid-swift
// together with its release binaries (2026-10), which broke every iOS build at
// package resolution (ios-build.yml red on main since 2026-10-05). This local
// package is the Swift twin of core/vendor/breez-sdk (PR #586): the bindings
// sources are committed here, exactly as Breez generated them for 0.12.4; the
// xcframework is Breez's own 0.12.4 binaries (iOS static libraries from Breez's
// Maven KMP artifacts, macOS dylib from the PyPI wheel) re-wrapped and hosted on
// this repository's releases, pinned by checksum. Provenance, every input hash
// and the reproduce steps are in MIRROR.md next to this file.
//
// 0.12.4 is the engine the shipped TestFlight builds (≤ 1.15.4) and the
// Android/desktop KMP package use, so an existing legacy wallet store opens.
let package = Package(
    name: "BreezSDKLiquid",
    platforms: [
        .iOS(.v16),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "BreezSDKLiquid", targets: ["BreezSDKLiquid"]),
    ],
    targets: [
        .binaryTarget(
            name: "breez_sdk_liquidFFI",
            url: "https://github.com/hedwig-corp/bitchat-to-sonar/releases/download/breez-sdk-liquid-ffi-0.12.4/breez_sdk_liquidFFI.xcframework.zip",
            checksum: "3bb2c9096e35b0a7568ad8a7618b641e0cca15992300b37a2d731948f6f8463e"
        ),
        .target(
            name: "BreezSDKLiquid",
            dependencies: [.target(name: "breez_sdk_liquidFFI")],
            path: "Sources/BreezSDKLiquid"
        ),
    ]
)
