# Android — build, run, and release APKs

Compose Multiplatform app lives in `apps/sonar/`. The Gradle build invokes
`core/build-android.sh` automatically (via `:composeApp:buildAndroidRustCore`)
to produce `libsonar_ffi.so` + UniFFI Kotlin under `composeApp/src/androidMain/`.

For agent/workspace rules that mention Android, see also `CLAUDE.md`
(**Android Build & Run**).

## Prerequisites

- JDK 17+
- Android SDK (`ANDROID_HOME` or `ANDROID_SDK_ROOT`)
- Android NDK (for the Rust JNI core; `cargo-ndk` + NDK are used by
  `core/build-android.sh`). If `ANDROID_NDK_HOME` is unset, the script picks the
  newest install under `$ANDROID_SDK_ROOT/ndk/`.
- Rust toolchain with Android targets (the build script adds them as needed):
  `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`
- Device or emulator with **USB debugging** enabled for `installDebug`

### Secrets (gitignored — never commit)

| Secret / file | Purpose | Where |
|---------------|---------|--------|
| `breez.apiKey` or env `BREEZ_API_KEY` | Lightning wallet (Breez) | `apps/sonar/local.properties` |
| `composeApp/google-services.json` | FCM / offline payment wakeups | next to the Android module (gitignored if present) |

`local.properties` is also where Android Studio writes `sdk.dir=…`. Example
wallet key line (do not commit the real value):

```properties
sdk.dir=/Users/you/Library/Android/sdk
breez.apiKey=YOUR_BREEZ_API_KEY
# Optional private push stack overrides:
# sonar.nds.url=https://nds.example.com
# sonar.transponder.npub=npub1…
```

Without a Breez key the app still builds and runs chat; wallet/payment paths
will not work. Without `google-services.json`, FCM configure may be skipped and
offline payment notifications will not register (same class of issue as missing
iOS `GoogleService-Info.plist`).

## Day-to-day: run on a phone or emulator

From the repo root:

```bash
cd apps/sonar

# Install + launch debug on the default connected device/emulator (arm64).
./gradlew :composeApp:installDebug

# Or build the debug APK only:
./gradlew :composeApp:assembleDebug
# → composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

Debug is **arm64-v8a only** (modern phones + Apple Silicon emulators) so the
APK stays small. Connect a device with:

```bash
adb devices
adb install -r composeApp/build/outputs/apk/debug/composeApp-debug.apk
```

### Manual Rust core rebuild

Usually unnecessary — Gradle depends on `buildAndroidRustCore`. Force a core
rebuild after native changes or a clean tree:

```bash
# From repo root
ANDROID_NDK_HOME=/path/to/ndk core/build-android.sh

# Optional: skip voice-call audio stack for a smaller messaging-only .so
SONAR_FEATURES="" core/build-android.sh
```

Outputs:

- `apps/sonar/composeApp/src/androidMain/jniLibs/<abi>/libsonar_ffi.so`
- `apps/sonar/composeApp/src/androidMain/kotlin/uniffi/sonar_ffi/…`

## Release / sideload APKs

```bash
cd apps/sonar

# Default release: phones only (~half the universal size)
#   ABIs: arm64-v8a (modern) + armeabi-v7a (older 32-bit)
./gradlew :composeApp:assembleRelease
# → composeApp/build/outputs/apk/release/composeApp-release-unsigned.apk

# Universal fat APK: phones + emulator ABIs (x86 / x86_64, etc.)
./gradlew :composeApp:assembleRelease -Psonar.universalApk=true
```

| Variant | Gradle | Typical ABIs | Use |
|---------|--------|--------------|-----|
| Debug | `assembleDebug` / `installDebug` | arm64-v8a | Local dev |
| Release (phone) | `assembleRelease` | arm64-v8a, armeabi-v7a | GitHub alpha for real devices |
| Release (universal) | `assembleRelease -Psonar.universalApk=true` | + x86/x86_64 | Emulators + all devices |

Release APKs are **unsigned** unless you configure signing. Sideload requires
“install unknown apps” on the device. GitHub pre-releases typically attach:

- `sonar-*-android.apk` — phone ABIs  
- `sonar-*-android-universal.apk` — universal  

Website download (`web/src/lib/links.js`) points at the **phone** APK.

## Common pitfalls

1. **Missing NDK** — `core/build-android.sh` fails with “set ANDROID_NDK_HOME”.
   Install an NDK via SDK Manager and export `ANDROID_NDK_HOME`.
2. **Empty wallet** — no `breez.apiKey` / `BREEZ_API_KEY`; chat works, payments
   do not.
3. **Huge APK** — you built universal (or an old unfiltered release). Use default
   `assembleRelease` for phones-only.
4. **Emulator is x86_64** — debug is arm64-only; use an **arm64** system image
   (or the universal release APK for x86 emulators).
5. **Stale native lib** — after `core/` changes, run a clean rebuild:
   `./gradlew :composeApp:clean :composeApp:installDebug` or re-run
   `core/build-android.sh`.

## Zapstore

Publish signed phone APKs to [Zapstore](https://zapstore.dev): see
[`docs/ZAPSTORE.md`](ZAPSTORE.md) and `scripts/zapstore-publish.sh`. Requires a
**v2+ signed** release APK (configure keystore via `local.properties`) and
`SIGN_WITH` (Nostr nsec / bunker / browser). Alpha GitHub tags need
`--pre-release`.

## Related

- App overview: [`apps/sonar/README.md`](../apps/sonar/README.md)
- Zapstore: [`docs/ZAPSTORE.md`](ZAPSTORE.md)
- Isolated MDK v0.9.4 experiment: [`docs/DARKMATTER-ANDROID.md`](DARKMATTER-ANDROID.md)
- Push / FCM: [`docs/android-push-integration.md`](android-push-integration.md)
- Wallet: [`docs/WALLET-INTEGRATION.md`](WALLET-INTEGRATION.md)
- iOS archive / secrets rules: `CLAUDE.md`
