# Sonar Darkmatter (Android)

Sonar Darkmatter is a separately installable Android messaging experiment built
from the stable MDK `v0.9.4` release. It is not an upgrade to Sonar.

## Isolation contract

| Boundary | Sonar | Sonar Darkmatter |
| --- | --- | --- |
| Package id | `chat.bitchat.sonar` | `chat.bitchat.sonar.darkmatter` |
| Android app module | `composeApp` | `darkmatterApp` |
| Protocol library | legacy Sonar FFI / MDK 0.8 | upstream `marmot-uniffi` v0.9.4 |
| App data and preferences | production sandbox | separate Android sandbox |
| Identity secret | Sonar Android Keystore scope | separate Darkmatter Keystore scope |
| Database | Sonar SQLCipher store | MDK v0.9.4 SQLCipher account store |
| Signing certificate | Sonar release key | separate Darkmatter release key |
| Zapstore entry | `zapstore.yaml` | `zapstore-darkmatter.yaml` |
| Firebase / wallet | supported when configured | not linked or packaged |

The manifest disables Android backup, device transfer, and cleartext traffic.
MarmotKit stores its runtime under `noBackupFilesDir/marmot-v0.9.4`; pending
outbox messages use a separate Android-Keystore AES-GCM key. The app does not
import an nsec, database, wallet, preferences, files, or push token from Sonar.

## Reproducible MDK input

`core/build-darkmatter-android.sh` checks out the official `v0.9.4` tag and
refuses to build unless it resolves to:

```text
e391adc133a9b60e420da7a0446f014a180ac8d2
```

The script invokes that release's official `marmot-uniffi/kotlin-bindings.sh`.
Generated Kotlin and JNI libraries stay under Gradle's build directory and are
not committed. The upstream toolchain is Rust 1.90.0.

Prerequisites:

- Android SDK 35 and NDK `27.0.12077973`
- Rust/rustup (the script installs the selected Android Rust targets)
- Git/network access for the pinned MDK checkout and locked Cargo dependencies

Build and test:

```bash
cd apps/sonar
./gradlew :darkmatterApp:testDebugUnitTest
./gradlew :darkmatterApp:assembleDebug
./gradlew :darkmatterApp:assembleRelease
```

The normal phone build contains `arm64-v8a` and `armeabi-v7a`. Override the
native build for an emulator when needed:

```bash
DARKMATTER_ANDROID_ABIS='arm64-v8a x86_64' \
  ./gradlew :darkmatterApp:assembleDebug
```

## Local-first behavior

- Account and chat-list state is read from the encrypted local store before
  `Marmot.start()` connects to relays.
- Timeline reads use a 50-row page and retain at most 250 rendered rows.
- Starting a chat writes a local pending conversation immediately. Up to 32
  messages can be queued and survive process restart while KeyPackage/group
  setup runs in the background.
- Successful setup reconciles the pending row to the MDK group. Failed setup or
  sends stay visible and retryable.

## Independent signing and Zapstore

Never reuse Sonar's keystore variables. Configure the Darkmatter key in
gitignored `apps/sonar/local.properties`:

```properties
darkmatter.keystore=/absolute/path/to/darkmatter-upload.jks
darkmatter.keystore.password=...
darkmatter.key.alias=darkmatter
darkmatter.key.password=...
```

Or set `DARKMATTER_KEYSTORE`, `DARKMATTER_KEYSTORE_PASSWORD`,
`DARKMATTER_KEY_ALIAS`, and `DARKMATTER_KEY_PASSWORD`.

Link that certificate to the Zapstore publisher identity once, then run:

```bash
export SIGN_WITH='bunker://...'
scripts/zapstore-darkmatter-publish.sh --local
```

## Intentional platform and feature gaps

The first Sonar Darkmatter release is Android-only and messaging-only. It does
not ship the Sonar wallet, Bluetooth mesh, calls, FCM/transponder push, media,
or an Apple app. This is an explicit exception to normal cross-platform feature
delivery while the rewritten protocol/storage lifecycle is validated.

Follow-up path: after Android identity durability, restart recovery, group
interop, and local-first performance pass device testing, package the same
upstream MarmotKit UniFFI surface for the native Apple shell and decide which
Sonar features can be safely reintroduced without sharing production state.
