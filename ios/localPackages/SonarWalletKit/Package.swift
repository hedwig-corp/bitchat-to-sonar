// swift-tools-version:5.9
import PackageDescription

// SonarWalletKit: Lightning wallet engine (Breez SDK Liquid via the
// unify-wallet KMP `shared/wallet-kit` module) + a thin Swift layer.
//
// Frameworks/SonarWalletKit.xcframework is BUILT from the unify-wallet
// repo (branch sonar-wallet-kit):
//   ./gradlew :shared:wallet-kit:assembleSonarWalletKitReleaseXCFramework
// then copied here. See docs/WALLET-INTEGRATION.md.
//
// iOS-only: the KMP framework has no macOS slice, so this product must be
// linked ONLY into the iOS app target.
let package = Package(
    name: "SonarWalletKit",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "WalletKit",
            targets: ["WalletKit"]
        ),
    ],
    targets: [
        // Thin Swift layer: Keychain-backed storage + async/await façade.
        .target(
            name: "WalletKit",
            dependencies: [
                "SonarWalletKit",
            ],
            path: "Sources"
        ),
        // Kotlin/Native static framework (iosArm64 + iosSimulatorArm64).
        .binaryTarget(
            name: "SonarWalletKit",
            path: "Frameworks/SonarWalletKit.xcframework"
        ),
    ]
)
