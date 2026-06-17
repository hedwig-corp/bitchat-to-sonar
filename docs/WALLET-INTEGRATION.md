# Wallet integration (Breez SDK Liquid via unify-wallet)

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
runtime; when empty the service stays `.notConfigured` (wallet UI hides)
and throws `WalletBridgeError.missingAPIKey`.

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
