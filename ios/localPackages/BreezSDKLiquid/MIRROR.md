# Vendored: Breez SDK Liquid Swift bindings 0.11.13

Why this exists: `github.com/breez/breez-sdk-liquid-swift` (the package the
project pinned at 0.12.4) and its release asset
`breez_sdk_liquidFFI.xcframework.zip` return 404 since around 2026-10-05.
Breez has retired the Liquid SDK. Every iOS build failed at Swift package
resolution until this local package replaced the remote reference in
`ios/bitchat.xcodeproj` and `ios/localPackages/SonarWalletKit/Package.swift`.
Same situation and same fix shape as `core/vendor/breez-sdk` (PR #586).

## Contents

- `Sources/BreezSDKLiquid/` — the Swift bindings exactly as published in the
  `0.11.13` tag, taken from the `lnflash/breez-sdk-liquid-swift` mirror
  (`https://github.com/lnflash/breez-sdk-liquid-swift/archive/refs/tags/0.11.13.tar.gz`,
  commit `8bc1203b` "Mirror Breez SDK - Liquid Swift bindings 0.11.13,
  unmodified"). Unmodified.
- `LICENSE` — MIT, as Breez published it.
- The binary `breez_sdk_liquidFFI.xcframework` is NOT committed (358 MB). The
  `binaryTarget` points at the mirror's release asset and pins it by checksum:
  `613cec741ec850ca83561de8353553de9a2201685f94d7e2c306747404910241`
  (verified 2026-10-15 with `swift package compute-checksum`; the mirror's own
  `MIRROR.md` states the same value and that the archive was re-zipped from
  the CocoaPods cache, contents byte-identical to Breez's 0.11.13 publish).

## Version

0.11.13 is the last release anyone still hosts; the project previously used
0.12.4. The legacy Breez wallet is opt-in (it only opens when a store already
exists; Cashu is the primary wallet), so the surface Sonar touches is small —
see the compile notes in the PR that introduced this directory for the
API differences that had to be adapted.

## Known limitation: a wallet store last opened by 0.12.4

The Rust engine inside the 0.11.13 xcframework carries older SQLite
migrations than 0.12.4 (`core/vendor/breez-sdk-liquid` adds
`payment_details.settled_at` and replaces `wallet_updates` with
`wallet_cache_kv`). Breez's persister runs `Migrations::to_latest`, which
refuses a database that is AHEAD of the engine (`DatabaseTooFarAhead`). So a
legacy Breez wallet directory that a 0.12.4 build (TestFlight ≤ 1.15.4) already
opened will not open under this package: `LegacyBreezWallet` logs the connect
failure and shows the wallet as unavailable; nothing is deleted, the seed stays
in the keychain, and the same nsec restores the wallet on Android (still on
the 0.12.4 KMP package) or on an iOS build with a 0.12.4 engine. Fresh installs
and users who never had the legacy wallet (Cashu is the primary wallet) are
unaffected. The durable fix is to build a 0.12.4 xcframework from the vendored
Rust sources — tracked as a follow-up.

### Why this package is not simply 0.12.4 (checked 2026-10-15)

- The 0.11.13 binary really lacks the 0.12.4 migrations: `strings` on its
  `ios-arm64` slice has no `settled_at` and no `wallet_cache_kv`, and still
  carries `wallet_updates`; the vendored 0.12.4 `lib/core/src/persist/
  migrations.rs` adds both. So the limitation above is real, not theoretical.
- Nothing left to rebuild 0.12.4 from: `core/vendor/breez-sdk-liquid` holds
  `lib/core` only (no `lib/bindings`, which owned the uniffi scaffolding and
  the xcframework assembly); Maven never served the KMP iOS klibs
  (`breez-sdk-liquid-kmp-{iosarm64,iossimulatorarm64,macosarm64}` 0.12.4 →
  404) and the cached `-jvm` jar contains compiled classes only (no UDL,
  no Kotlin sources); `~/.cargo/git` has no Breez checkout any more; the
  upstream tag is gone. Reconstructing the uniffi surface by hand is a
  separate project — see the follow-up.

## If the mirror disappears too

Download the asset while it is up, verify the checksum above, and either host
it on a release of this repository (then change the `url`) or commit it as a
`path:` binary target. Nothing here is maintained upstream any more.
