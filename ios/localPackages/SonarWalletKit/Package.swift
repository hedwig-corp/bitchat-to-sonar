// swift-tools-version:5.9
import PackageDescription

// WalletKit: the Sonar Lightning wallet — a thin Swift façade over the OFFICIAL
// Breez SDK Liquid Swift bindings (prebuilt xcframework via SPM). This replaces
// the old `SonarWalletKit` KMP framework (built from the unify-wallet repo): Sonar
// isn't reusing unify-wallet's Kotlin, so we consume Breez directly — the same way
// the Android/desktop app uses the Breez KMP package.
let package = Package(
    name: "SonarWalletKit",
    platforms: [
        .iOS(.v16),
        .macOS("15.0"),
    ],
    products: [
        .library(
            name: "WalletKit",
            targets: ["WalletKit"]
        ),
    ],
    dependencies: [
        // Breez SDK Liquid Swift bindings, vendored: upstream deleted the package
        // and its binaries (see ../BreezSDKLiquid/MIRROR.md). 0.11.13 is the last
        // mirrored release; the Android/desktop KMP package stays on 0.12.4.
        .package(path: "../BreezSDKLiquid"),
    ],
    targets: [
        // Thin Swift layer: Keychain-backed seed + async/await façade over Breez.
        .target(
            name: "WalletKit",
            dependencies: [
                .product(name: "BreezSDKLiquid", package: "BreezSDKLiquid"),
            ],
            path: "Sources"
        ),
    ]
)
