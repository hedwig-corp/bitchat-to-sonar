// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tor",  // Keep name "Tor" for drop-in compatibility
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "Tor",
            targets: ["Tor"]
        ),
    ],
    dependencies: [
        .package(path: "../BitLogger"),
    ],
    targets: [
        // Main Swift target
        .target(
            name: "Tor",
            dependencies: [
                "arti",
                .product(name: "BitLogger", package: "BitLogger"),
            ],
            path: "Sources",
            exclude: ["C"],
            sources: [
                "TorManager.swift",
                "TorURLSession.swift",
                "TorNotifications.swift",
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedLibrary("z"),
                // NOTE: do NOT link the system `sqlite3` here. Arti only *imports*
                // sqlite3 symbols (32 undefined, 0 defined); linking the iOS
                // system /usr/lib/libsqlite3.dylib makes its plain-SQLite symbols
                // satisfy EVERY sqlite3_* call in the app — including SonarCore's —
                // which shadows the SQLCipher built into libsonar_ffi.a. The result
                // is `PRAGMA cipher_version` == empty, so MDK rejects the encrypted
                // Marmot store ("SQLCipher support is not active") and White Noise
                // chats fail to open. With this line removed, Arti's sqlite3 imports
                // resolve to SonarCore's bundled SQLCipher (a full SQLite superset),
                // so Tor's plain DB and Marmot's encrypted DB both work.
            ]
        ),
        // Binary framework containing the Rust static library
        .binaryTarget(
            name: "arti",
            path: "Frameworks/arti.xcframework"
        ),
    ]
)
