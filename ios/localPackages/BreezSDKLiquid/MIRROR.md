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

## If the mirror disappears too

Download the asset while it is up, verify the checksum above, and either host
it on a release of this repository (then change the `url`) or commit it as a
`path:` binary target. Nothing here is maintained upstream any more.
