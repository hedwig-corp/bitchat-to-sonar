// swift-tools-version:5.9
import PackageDescription

// BreezSDKLiquid — vendored Swift bindings for the Breez SDK Liquid.
//
// Breez retired the Liquid SDK and deleted github.com/breez/breez-sdk-liquid-swift
// together with its release binaries (2026-10), which broke every iOS build at
// package resolution (ios-build.yml red on main since 2026-10-05). This local
// package is the Swift twin of core/vendor/breez-sdk (PR #586): the bindings
// sources are committed here, the prebuilt xcframework is pinned by checksum to
// the only surviving mirror (lnflash/breez-sdk-liquid-swift, tag 0.11.13).
// Provenance and the exact checksum are in MIRROR.md next to this file.
//
// Version note: this is 0.11.13, the last mirrored release; the app previously
// pinned 0.12.4. See MIRROR.md for the API delta that mattered to Sonar.
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
            url: "https://github.com/lnflash/breez-sdk-liquid-swift/releases/download/0.11.13/breez_sdk_liquidFFI.xcframework.zip",
            checksum: "613cec741ec850ca83561de8353553de9a2201685f94d7e2c306747404910241"
        ),
        .target(
            name: "BreezSDKLiquid",
            dependencies: [.target(name: "breez_sdk_liquidFFI")],
            path: "Sources/BreezSDKLiquid"
        ),
    ]
)
