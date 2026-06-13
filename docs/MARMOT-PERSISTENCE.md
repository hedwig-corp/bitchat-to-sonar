# Marmot persistence (encrypted SQLCipher store)

Status: implemented in `sonar-core` + `sonar-ffi`, cross-builds for iOS.
Date: 2026-06-12.

## What changed

White Noise / Marmot chats (MLS groups + messages + MLS secrets) now persist
across app restarts. The Rust core switched from `MdkMemoryStorage` (volatile)
to `mdk-sqlite-storage` 0.8.0, which is an **encrypted SQLCipher** database.

## Storage choice: encrypted SQLCipher via Apple CommonCrypto

We use the **encrypted** path (`MdkSqliteStorage::new_with_key`), not plain
sqlite, for two reasons:

1. **There is no plain-sqlite option.** `mdk-sqlite-storage` 0.8.0 hardcodes
   `rusqlite = { features = ["bundled-sqlcipher"], default-features = false }`
   in its own `Cargo.toml`. You cannot select rusqlite's plain `bundled` feature
   without forking the crate. Its only unencrypted constructor,
   `new_unencrypted`, is gated behind `#[cfg(any(test, feature = "test-utils"))]`
   and is unavailable in production. So the encrypted path is the *only* viable
   path — and it cross-builds fine (below), so the documented plain+DataProtection
   fallback was never needed.

2. **No OpenSSL cross-compile needed.** SQLCipher on Apple platforms can use
   **CommonCrypto** instead of OpenSSL. The `libsqlite3-sys` 0.35 `build.rs`
   already does this automatically: when `host` and `target` are both Apple and
   **no OpenSSL is advertised via env**, it compiles SQLCipher with
   `-DSQLCIPHER_CRYPTO_CC` and emits
   `cargo:rustc-link-lib=framework=Security` + `=CoreFoundation`. No OpenSSL,
   no vendored crypto, clean cross-build for `aarch64-apple-ios` and
   `aarch64-apple-ios-sim`.

   The earlier "bundled-sqlcipher needs OpenSSL on iOS" learning was wrong/
   environment-specific: it only fails if `OPENSSL_DIR` / `OPENSSL_LIB_DIR` /
   `OPENSSL_INCLUDE_DIR` are set (which flips the build into the OpenSSL branch).
   `core/build-ios.sh` now `unset`s those vars to force the CommonCrypto path
   reproducibly.

## Key ownership

`MdkSqliteStorage::new(path, service_id, db_key_id)` would use the OS keyring to
mint/fetch the key — unreliable from a Rust static lib on iOS. We bypass it and
use `new_with_key(path, EncryptionConfig::new(key: [u8; 32]))`:

- The **host owns the 32-byte SQLCipher key**. On iOS the Swift side generates it
  once, stores it in the **Keychain**, and passes the same value (hex-encoded)
  on every launch so the existing database reopens.
- A wrong key fails to open the database (verified by a test).

## Build flags (baked into `core/build-ios.sh`)

The script unsets the OpenSSL discovery env vars before building so the Apple
CommonCrypto branch is always taken:

```sh
unset OPENSSL_DIR OPENSSL_LIB_DIR OPENSSL_INCLUDE_DIR OPENSSL_NO_VENDOR \
      OPENSSL_STATIC LIBSQLITE3_SYS_USE_PKG_CONFIG
```

No other flags are required. `Security` + `CoreFoundation` linkage is declared in
`localPackages/SonarCore/Package.swift` (`.linkedFramework(...)`) because a
static-lib xcframework does not propagate the Rust `cargo:rustc-link-lib`
directives to the Xcode consumer.

## Rust API surface

`sonar-core`:

- `MarmotEngine::in_memory(identity)` — volatile (tests, anonymous sessions).
- `MarmotEngine::persistent(identity, db_path, key: [u8; 32]) -> Result<Self>`
  — encrypted SQLCipher store at `db_path`.
- `MarmotEngine::wipe(db_path) -> Result<()>` — deletes the db + `-wal`/`-shm`/
  `-journal` sidecars; idempotent.
- `SonarClient::connect(identity, relays, db_path, db_key: [u8; 32])` —
  persistent.
- `SonarClient::connect_in_memory(identity, relays)` — volatile (tests).
- `SonarClient::wipe_database(db_path)` — free function for panic-wipe.

## FFI surface the Swift host must call

Generated into `localPackages/SonarCore/Sources/SonarFFI.swift`:

```swift
// Connect with a persistent, encrypted store.
let node = try SonarNode.connect(
    identity: identity,            // SonarIdentity
    relayUrls: ["wss://relay…"],   // [String]
    dbPath: "<Application Support>/sonar-marmot/marmot.sqlite",  // String
    dbKeyHex: "<64-char hex of the 32-byte Keychain key>"        // String
)

// Panic-wipe: drop the node first, then erase the DB, then clear the Keychain key.
try wipeMarmotDatabase(dbPath: "<…>/marmot.sqlite")
```

Swift host responsibilities:

1. Create the parent directory of `dbPath`, ideally with
   `FileProtectionType.complete` (Data Protection).
2. Generate a random 32-byte key on first run, store it in the Keychain
   (e.g. `AfterFirstUnlockThisDeviceOnly`), pass it hex-encoded as `dbKeyHex`
   every launch.
3. On panic-wipe: release the `SonarNode`, call `wipeMarmotDatabase(dbPath:)`,
   then delete the Keychain key.

## Tests (all green via `cd core && cargo test`)

- `tests/e2e.rs` — unchanged in-memory two-instance e2e (now uses
  `connect_in_memory`).
- `tests/persistence.rs`:
  - `group_and_message_survive_reopen` — create group + message on a SQLCipher
    engine at a tempdir path, **drop** the engine, reopen a **new** engine at the
    **same path + key**, assert the group + message are still present.
  - `wrong_key_cannot_open_existing_db` — a different key is rejected.
  - `wipe_removes_the_database` — wipe deletes the file and is idempotent.
- `sonar-ffi` unit tests cover bad-input rejection on `connect` and idempotent
  `wipeMarmotDatabase`.

## Artifact

`localPackages/SonarCore/Frameworks/sonarffi.xcframework` (~468M; slices:
`ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64`). Rebuild with
`core/build-ios.sh`.
