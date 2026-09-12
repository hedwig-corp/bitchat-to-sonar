# Wallet integration

> **Direction of travel (2026-07):** the wallet contract now lives in Rust as
> `core/sonar-wallet` (`WalletBackend` trait + nsec→seed derivation +
> destination classification), with Breez SDK Liquid implementing it in
> `core/sonar-wallet-breez`. The per-platform Breez integrations described
> below are what ships today; they are scheduled for replacement by that
> interface over a staged PR train (desktop → Android → iOS app → iOS
> **Migration surface (PR3).** `SonarCashuWallet` and `SonarMigration` are
> exported from sonar-ffi; the Breez side of a migration is the foreign trait
> `HostMigrationSource`, implemented per app over the EXISTING native Breez
> integrations (`SonarWallet` on Apple, `WalletBridge` on Compose) — Breez-rust
> can never enter sonar-ffi because its forked libsqlite3-sys links plain
> sqlite3 and would collide with sonar-core's SQLCipher. The source ships on
> all three surfaces: Apple, Compose Android, and Compose Desktop (jvmMain
> gets its own UniFFI bindings from `build-desktop.sh`, so it hosts the engine
> too).
>
> notification extension). The Cashu backend (`core/sonar-wallet-cdk`, PR
> #582) is core-only for now on BOTH app surfaces — an explicit tracked gap
> per the Cross-Platform Feature Rule: apps reach wallet backends through the
> sonar-ffi surface, which lands with the platform cutovers; the follow-up
> path is the guided Breez→Cashu migration flow (PR3 of the train) plus the
> per-platform cutover PRs. Background and the decisions behind it:
> [`docs/brainstorms/2026-07-26-wallet-interface-bolt12.md`](brainstorms/2026-07-26-wallet-interface-bolt12.md).
>
> Two constraints that will not go away, and that any wallet work must respect:
>
> 1. **`sonar-wallet-breez` is a build island, not a workspace member.**
>    `breez-sdk-liquid` ships a forked `libsqlite3-sys` (`links = "sqlite3"`,
>    plain bundled SQLite) that cannot coexist in one cargo graph with the
>    SQLCipher `libsqlite3-sys` the Marmot store uses — and must not share a
>    binary with it either, which is the symbol-shadowing class that once broke
>    iOS Marmot encryption. On iOS the Breez backend therefore has to ship as a
>    separate dynamic framework (roughly the isolation the prebuilt
>    `breez-sdk-liquid-swift` xcframework already provides), and `sonar-cli`
>    can never link it — the headless proof is
>    `core/sonar-wallet-breez/src/bin/sonar-wallet-cli.rs`.
> 2. **The wallet seed derivation is wallet identity.**
>    HKDF-SHA256(nsec secret, salt `"sonar-wallet"`, info `"sonar-bolt12-v1"`,
>    32 bytes) handed to Breez as the *raw* seed — never via a BIP39 mnemonic,
>    which derives a different wallet. Pinned by a golden vector shared with
>    `ios/bitchatTests/Services/SonarWalletDerivationTests.swift`.

## Breez → Cashu migration

`core/sonar-wallet-migrate` owns the funds-safety state machine. The apps host
the existing Breez wallet behind sonar-ffi's `HostMigrationSource`; Cashu is
the Rust `SonarCashuWallet` destination. Apple implements the host in
`ios/bitchat/Views/Sonar/WalletMigration.swift`, while Compose Android and
Desktop implement it through `WalletMigrationController` and the platform
`WalletBridge`.

The Cashu working directory contains the durable, account-and-mint-bound
`cashu.migration.v1.json` journal. Its normal progression is
`AwaitingConsent` → `Sending` → `PaymentUnknown` / `SourcePending` /
`SourcePaid` → `MintPaid` → `Settled`. `Sending` is atomically persisted and
fsynced before the source `send`, so an app restart cannot resend an ambiguous
payment. Corrupt or misbound journal data fails closed. Wallet replacement and
emergency wipe remove the Cashu root, including the journal, temp, and lock
artifacts.

Every plan records two independent identities:

- `payment_hash` identifies the outgoing Lightning payment.
  `HostMigrationSource.lookup_payment(payment_hash)` returns a typed
  `HostPaymentLookupStatus`, allowing resume to distinguish pending, complete,
  failed/refundable, and unknown outcomes.
- `settlement_id` identifies the exact Cashu mint quote.
  `reconcile_tracked_receive(settlement_id, timeout)` settles only that quote;
  unrelated Cashu credits and aggregate balance deltas do not count.

`SonarMigration.status()` exposes the journaled state without spending.
`resume(polls:)` first reconciles the source payment when its outcome is
ambiguous, then reconciles the exact destination quote. A post-payment timeout
or app restart remains a pending migration with a safe "check again" path; only
an `AwaitingConsent`/`ExpiredUnsent` attempt may be cancelled and replanned.
The headless `sonar-migrate-cli status`/`settle --settle-polls N` commands use
the same journal. `settle` has no baseline-balance argument, and `migrate`
prints the settlement id, payment hash, current state, and resume command after
the source attempt returns and before settlement polling begins.

Host errors are non-flat `HostWalletError` values. `InsufficientFunds` must
remain a distinct variant across UniFFI so bounded whole-balance drain
step-down can run; all other failures retain diagnostic text. The Compose host
maps the typed variant directly. Apple currently maps its native
`insufficientAfterFee` case directly and retains a message fallback for native
errors that WalletKit has not typed yet.

## Current iOS integration (Breez SDK Liquid via unify-wallet)

Sonar embeds a Lightning wallet (Breez SDK Liquid, BOLT12/BIP-353 capable)
by reusing the wallet slice of the **unify-wallet** KMP codebase instead of
binding the Breez SDK directly. iOS-only: the Kotlin/Native framework has no
macOS slice, so the macOS target builds without any wallet code.

## Layers

```
bitchat/Services/WalletBridgeService.swift   app facade (#if os(iOS), @MainActor,
                                             no singleton; state machine
                                             notConfigured/settingUp/ready(balanceSats))
        │ async/await
localPackages/SonarWalletKit  (SPM, product "WalletKit")
  Sources/SonarWallet.swift            async façade over the callback bridge
  Sources/KeychainWalletStorage.swift  WalletKitStorage SPI impl (Security framework,
                                       service "chat.bitchat.sonar.wallet")
  Frameworks/SonarWalletKit.xcframework  Kotlin/Native binary (checked in, rebuilt below)
        │ ObjC interop (SWK* classes, swift_name-mapped)
unify-wallet  shared/wallet-kit  (branch sonar-wallet-kit)
  SonarWalletComponent   wallet-only composition root (KeyManager + Breez node/wallet
                         + WalletService; storage injected by host)
  IosWalletBridge        coroutine→callback wrapper; ALL callbacks fire on the main thread
  WalletKitStorage       synchronous storage SPI (sync because Swift classes cannot
                         implement Kotlin suspend interface members); adapted internally
                         to the suspend KeyValueStore on Dispatchers.Default
  NoOpCloudBackupProvider  no Google Drive; host owns backup policy
```

## Rebuilding the xcframework

The binary framework is built from the unify-wallet repo, branch
**`sonar-wallet-kit`** (currently local-only at `/tmp/unify-wallet`, commit
`4e0bdf6`; it should eventually be PR'd to
[hedwig-corp/unify-wallet](https://github.com/hedwig-corp/unify-wallet)):

```sh
cd /tmp/unify-wallet            # branch sonar-wallet-kit
./gradlew :shared:wallet-kit:assembleSonarWalletKitReleaseXCFramework
rm -rf <sonar-repo>/localPackages/SonarWalletKit/Frameworks/SonarWalletKit.xcframework
cp -R shared/wallet-kit/build/XCFrameworks/release/SonarWalletKit.xcframework \
      <sonar-repo>/localPackages/SonarWalletKit/Frameworks/
```

Slices: `ios-arm64` + `ios-arm64-simulator`, static. After any Kotlin API
change, re-check `Headers/SonarWalletKit.h` — Swift names come from the
`swift_name` attributes (e.g. `SWKIosWalletBridge` → `IosWalletBridge`).

## Storage SPI

The wallet engine persists the BIP39 mnemonic and small wallet state
(e.g. the cached BOLT12 offer) through the host-provided `WalletKitStorage`:

```kotlin
interface WalletKitStorage {           // implemented in Swift
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun getBytes(key: String): ByteArray?
    fun putBytes(key: String, value: ByteArray)
    fun remove(key: String); fun clear(); fun contains(key: String): Boolean
}
```

`KeychainWalletStorage` (in the SPM package) backs it with generic-password
items under service **`chat.bitchat.sonar.wallet`**, accessibility
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It deliberately does NOT
use the app's `KeychainManager` so the package stays self-contained — note
this means `panicClearAllData()` does NOT wipe the wallet seed; call
`KeychainWalletStorage().clear()` explicitly if wallet wipe is wanted.

Implementations must be thread-safe: the Kotlin adapter calls them from
background dispatchers.

## API key

The Breez API key is injected via build settings → Info.plist:

- `Configs/Release.xcconfig` defines an empty default: `BREEZ_API_KEY =`
- `bitchat/Info.plist` carries `BREEZ_API_KEY = $(BREEZ_API_KEY)`
- **To enable the wallet locally**, add to the gitignored
  `Configs/Local.xcconfig` (included by Debug.xcconfig):

  ```
  BREEZ_API_KEY = <your Breez API key>
  ```

`WalletBridgeService.setupIfNeeded()` reads the key from Info.plist at
runtime; when empty the service stays `.notConfigured`, Settings Balance
shows **Unavailable** (Compose parity), and setup throws
`WalletBridgeError.missingAPIKey`. Debug may omit the key; Release app
targets refuse to build when it is empty (Xcode Run Script on
`bitchat_iOS` / `bitchat_macOS`).

## App facade usage

```swift
let wallet = WalletBridgeService()          // inject, no singleton
try await wallet.setupIfNeeded()            // configure → create wallet on
                                            // first run → start node
wallet.statePublisher                       // .notConfigured / .settingUp /
                                            // .ready(balanceSats:) — balance
                                            // updates live via observeBalance
let payment = try await wallet.send(destination: "user@domain", amountSats: 1000, note: "hi")
// destination = BOLT11 / BOLT12 offer / LNURL-pay / BIP-353 (resolved by Breez)
// payment.id / payment.feesSats feed Sonar's local activity list.
let offer = try await wallet.createOffer()  // reusable BOLT12 receive offer
let parsed = try await wallet.parseDestination("lno1...")
for await payment in wallet.incomingPayments() { ... }
```

Networks: `WalletBridgeService(mainnet: false)` for testnet; default mainnet.

## Gotchas

- Link the `WalletKit` product ONLY into the iOS app target — the
  xcframework has no macOS slice and would break the macOS link.
- `IosWalletBridge` callbacks arrive on the **main thread** (its coroutine
  scope is `Dispatchers.Main`); `SonarWallet` wraps them with checked
  continuations, `WalletBridgeService` is `@MainActor`.
- `SonarWalletComponent` is a Kotlin `object` (process-global) and its lazy
  DI graph captures `configure(...)` values on first access — configure
  exactly once per process, before any other call.
- Kotlin `Boolean`/`Long?` in callbacks surface as boxed `KotlinBoolean` /
  `KotlinLong` (`.boolValue` / `.int64Value`); `ByteArray` as
  `KotlinByteArray` (`size`/`get`/`set` with `Int32`/`Int8`).
- Kotlin `description` properties surface as `description_` (NSObject clash).
