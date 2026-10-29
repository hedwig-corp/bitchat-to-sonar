# Vendored: Breez SDK Liquid Swift bindings 0.12.4

Why this exists: `github.com/breez/breez-sdk-liquid-swift` (the package the
project pinned at 0.12.4) and its release asset
`breez_sdk_liquidFFI.xcframework.zip` return 404 since around 2026-10-05.
Breez has retired the Liquid SDK; `github.com/breez/breez-sdk-liquid` itself
was re-created empty (see `core/vendor/breez-sdk-liquid/VENDORED.md`). Every
iOS build failed at Swift package resolution until this local package replaced
the remote reference in `ios/bitchat.xcodeproj` and
`ios/localPackages/SonarWalletKit/Package.swift`. Same situation and same fix
shape as `core/vendor/breez-sdk` (PR #586).

A first cut of this package carried the 0.11.13 bindings from the
`lnflash/breez-sdk-liquid-swift` mirror, the only Swift release anyone still
hosted. That engine refused a legacy wallet store a 0.12.4 build had already
opened (below). This directory is now 0.12.4 again, built from Breez's own
published 0.12.4 artifacts rather than from a rebuild of the Rust sources: the
`lib/bindings` crate and the `lib/plugins/nwc` crate the 0.12.4 bindings link
were never vendored and no copy of their sources survives (GitHub forks,
Software Heritage, Wayback and cargo's git database were all checked). A
rebuild from `core/vendor/breez-sdk-liquid` alone would have had to stub the
NWC half of the FFI surface and would have re-resolved 116 dependency versions
Breez pinned on a money path. Breez's binaries do neither.

## Contents

- `Sources/BreezSDKLiquid/` — the Swift bindings exactly as Breez generated
  and published them for 0.12.4. Taken from `Quizzicarol/breez-sdk-liquid-flutter`,
  an unmodified mirror of Breez's `breez-sdk-liquid-flutter` repository, tag
  `v0.12.4` (commit `e4757b93ba2054b0ee74f483e05adeecc82530d2`, "chore: release
  Flutter package v0.12.4", 2026-06-17), directory `ios/Sources/BreezSDKLiquid/`
  (byte-identical to the mirror's `macos/Sources/BreezSDKLiquid/`). Breez's
  release workflow copied the same files into the Swift package and the
  Flutter plugin; the Flutter copy also carries `PluginManager.swift` and
  `Task/NwcEvent.swift`, which the 0.12.4 Swift package had too. Unmodified.
  Tarball `archive/refs/tags/v0.12.4.tar.gz` SHA-256
  `4094ae0a07cc281b21cf613ad8a252a59d379200277f793efeeeaa8cfcab12dc`.
- `LICENSE` — MIT, as Breez published it.
- The binary `breez_sdk_liquidFFI.xcframework` is NOT committed (193 MB zipped).
  The `binaryTarget` points at this repository's release
  `breez-sdk-liquid-ffi-0.12.4` and pins it by checksum
  `3bb2c9096e35b0a7568ad8a7618b641e0cca15992300b37a2d731948f6f8463e`
  (`swift package compute-checksum`, 2026-10-15). Its slices:

  | Slice | Binary | Source | SHA-256 of the binary as published |
  |---|---|---|---|
  | `ios-arm64` | static framework, `libbreez_sdk_liquid_bindings.a` | Breez Maven `mvn.breez.technology/releases/technology/breez/liquid/breez-sdk-liquid-kmp-iosarm64/0.12.4/…-cinterop-breezCInterop.klib` (klib SHA-256 `168e9939eddc71a29087e043e63f04d5e7c3171acfe432cda32d4b4ce6c76f00`, matches Maven's `.sha256`), member `default/targets/ios_arm64/included/libbreez_sdk_liquid_bindings.a` | `a3f6e4100b4945a13f491b9adfbe4b299afb9ab17f934185e128818573f6f4e4` |
  | `ios-arm64-simulator` | static framework, same name | same, `…-kmp-iossimulatorarm64/0.12.4/…-cinterop-breezCInterop.klib` (klib SHA-256 `6156514f0fbb366a349b5e752a1aaf85ad55e70752015561af1858c3a7cdb688`), member `default/targets/ios_simulator_arm64/included/libbreez_sdk_liquid_bindings.a` | `01733cd5b48655ee44d1118daee5627b497bd4a52f0efb1a0c7fbf2018c4e096` |
  | `macos-arm64_x86_64` | dynamic framework (versioned bundle), `libbreez_sdk_liquid_bindings.dylib` universal2 | PyPI `breez_sdk_liquid-0.12.4-cp312-cp312-macosx_11_0_universal2.whl` (wheel SHA-256 `c6184f1dd2e6ceccb12fb71b83c81de0e32b787c3f22225e6ada3773478bf154`, uploaded 2026-06-17), member `breez_sdk_liquid/libbreez_sdk_liquid_bindings.dylib` | `02d7a1ab6313795f3cb64a8e1b887cb584de64d521b9dbbc09ca93226e94b4d2` |

  The two static archives are byte-for-byte Breez's. The dylib differs from
  Breez's only by `install_name_tool -id
  @rpath/breez_sdk_liquidFFI.framework/Versions/A/breez_sdk_liquidFFI` and an
  ad-hoc signature (Xcode re-signs it on embed). The C header
  `breez_sdk_liquidFFI.h` in every slice is Breez's from the same Flutter tag
  (`ios/Classes/breez_sdk_liquidFFI.h`, SHA-256
  `99abd53218ee0be262bea9e72632413d002a88d10416353550319f7d4340ccc2`); the
  `module.modulemap` and `Info.plist` files are ours.

## Why these binaries are the 0.12.4 engine

All three come from Breez's release of the same day (2026-06-17) as the
`0.12.4` tag of the Rust repo (`e11d88c7…`, the commit vendored under
`core/vendor/breez-sdk-liquid`), and all three were compiled from the same
`breez_sdk_liquid_bindings` crate with the same UniFFI build (the breez fork of
`uniffi-rs`, `github.com/breez/uniffi-rs` @ `28d4dd2`, uniffi 0.28.3, contract
version 26 — the path is embedded in each binary). Checks done before pinning:

- UniFFI API checksums: every one of the 68 `uniffi_breez_sdk_liquid_bindings_checksum_*`
  values the Swift bindings assert at load time was read back from the PyPI
  dylib (`ctypes`); 68/68 match, nothing missing, nothing extra. The 0.11.13
  Swift bindings cover only 53 of them (the NWC plugin API is the delta).
  The static archives cannot be executed on the host; the simulator smoke test
  below exercises their checksum check at runtime instead.
- The two iOS archives link under Xcode 27's linker (they embed LLVM 22
  bitcode sections from Rust 1.96 that Apple's `nm` cannot parse; `ld` ignores
  them). `ios/bitchatTests/LegacyBreezStoreOpenTests.swift` connects through
  the simulator slice.
- A wallet store written by the PyPI 0.12.4 engine (schema `user_version` 46:
  `payment_details.settled_at`, `wallet_cache_kv` instead of `wallet_updates`)
  is the committed fixture `ios/bitchatTests/Fixtures/breez-0.12.4-storage.sql`;
  that test opens it in the simulator. 0.11.13 refused the same store.

Not recoverable, and therefore not here: the 0.12.4 `breez_sdk_liquid.udl`.
UniFFI library mode cannot regenerate bindings from these binaries (a UDL
crate only embeds the UDL's name), so `Sources/` cannot be re-derived from the
xcframework; it is pinned to the Flutter tag above instead.

## What changed for Sonar between 0.11.13 and 0.12.4

`ReceivePaymentRequest.descriptionHash` (was `useDescriptionHash`) and
`PaymentDetails.lightning.settledAt` — both back to their 0.12.4 spelling in
`ios/localPackages/SonarWalletKit/Sources/SonarWallet.swift`. The NSE's
`SDKNotificationService` subclass is unchanged: `TaskProtocol.start` gained a
`pluginConfigs:` parameter and `getPluginConfigs()` defaults to no NWC, which
Sonar does not use.

## macOS: the slice is a dynamic framework

Breez never published a macOS *static* 0.12.4 library anywhere that survives,
so the macOS slice wraps the PyPI dylib as a versioned dynamic framework.
Xcode embeds and signs it in `Sonar.app/Contents/Frameworks`. The project's
"Remove static Breez framework wrapper" build phase, which deleted the
previous package's uselessly embedded static framework on macOS, now only
removes the framework when its binary is a static archive. The desktop
Compose app is unaffected (it fetches its own host dylib through
`core/build-desktop.sh`).

## Reproduce the xcframework

```sh
# inputs (verify the hashes above first)
curl -LO https://mvn.breez.technology/releases/technology/breez/liquid/breez-sdk-liquid-kmp-iosarm64/0.12.4/breez-sdk-liquid-kmp-iosarm64-0.12.4-cinterop-breezCInterop.klib
curl -LO https://mvn.breez.technology/releases/technology/breez/liquid/breez-sdk-liquid-kmp-iossimulatorarm64/0.12.4/breez-sdk-liquid-kmp-iossimulatorarm64-0.12.4-cinterop-breezCInterop.klib
unzip -j '*iosarm64*.klib' 'default/targets/ios_arm64/included/*.a' -d dev
unzip -j '*iossimulatorarm64*.klib' 'default/targets/ios_simulator_arm64/included/*.a' -d sim
pip download --no-deps --only-binary=:all: --platform macosx_11_0_universal2 --python-version 3.12 breez-sdk-liquid==0.12.4
unzip -j breez_sdk_liquid-0.12.4-*.whl 'breez_sdk_liquid/*.dylib' -d mac
curl -L https://github.com/Quizzicarol/breez-sdk-liquid-flutter/archive/refs/tags/v0.12.4.tar.gz | tar xz
```

Then, per slice: a `breez_sdk_liquidFFI.framework` with the binary as
`breez_sdk_liquidFFI` (iOS: the `.a`; macOS: the dylib under `Versions/A/`,
install name set as above, ad-hoc signed), `Headers/breez_sdk_liquidFFI.h`
from the tarball's `ios/Classes/`, a `Modules/module.modulemap` declaring
`framework module breez_sdk_liquidFFI { umbrella header "breez_sdk_liquidFFI.h" export * module * { export * } }`,
and an `Info.plist` (`CFBundlePackageType` FMWK, executable and identifier
`breez_sdk_liquidFFI` / `technology.breez.liquid.breez-sdk-liquidFFI` (no underscores: Xcode validates the embedded bundle id),
version 0.12.4, `MinimumOSVersion` 13.0 on iOS, `LSMinimumSystemVersion` 11.0
on macOS). `xcodebuild -create-xcframework -framework … ×3 -output
breez_sdk_liquidFFI.xcframework`, `ditto -c -k --keepParent` to zip,
`swift package compute-checksum` for the pin. The fixture store:
`python3 -c 'import breez_sdk_liquid as b; …'` with the PyPI wheel on
`sys.path`, `default_config(MAINNET, None)`, Electrum explorers
(`blockstream.info:995`, `bitcoin-mainnet.blockstream.info:50002`),
`sync_service_url=None`, the BIP-39 "abandon ×11 about" mnemonic, then copy
`mainnet/73c5da0a/storage.sql`.

## Known limitation: no x86_64 simulator slice

Sonar builds its simulator slices arm64-only (`ARCHS=arm64`, like the Arti and
sonarffi xcframeworks); Breez's Maven KMP artifacts have no iOS x86_64
simulator binary either. The `layerztec/breez-sdk-liquid-rn-artifacts`
release `0.12.4` (`ios-artifacts.zip`, SHA-256
`4329619afda394b957707188798cb92f7ef0730c262559b48cb29a0107dfa195`) carries a
Breez-built `ios-arm64_x86_64-simulator` fat archive of the same crate if an
Intel simulator slice is ever needed.

## If Maven or PyPI disappear too

The release asset on this repository is the copy that matters; nothing here is
maintained upstream any more. Keep the hashes above with any re-host, and do
not point the package back at a Breez URL.
