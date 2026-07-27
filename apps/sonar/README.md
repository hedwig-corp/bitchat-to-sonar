# Sonar — Compose Multiplatform app

One Kotlin/Compose UI codebase (`composeApp/src/commonMain`) driving Sonar on
**Android** and **Desktop** (macOS / Windows / Linux). The shared UI + app state
([`SonarAppState`](composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt))
talk to a headless Rust core (`../../core`, White Noise / Marmot over Nostr) through
UniFFI/JNA bindings, plus per-platform `actual`s for radios, storage, notifications
and the wallet.

```
composeApp/src/
  commonMain/   shared UI (screens, theme, desktop shell) + SonarAppState + expect decls
  androidMain/  Android actuals (BLE mesh, Breez wallet, …) + MainActivity
  jvmMain/      Desktop actuals + Main.kt (Compose Desktop window)
  jvmTest/      Desktop FFI smoke test
```

## Platform support matrix

| Capability                          | Android | Desktop |
|-------------------------------------|:-------:|:-------:|
| White Noise (Marmot) secure DMs     |   ✅    |   ✅    |
| Geohash public channels + presence  |   ✅    |   ✅    |
| Encrypted media (MIP-04)            |   ✅    |   ✅    |
| Profiles / verify safety numbers    |   ✅    |   ✅    |
| Location channels ("Around you")    |   ✅ GPS | ⚪️ opt-in IP geolocation (Settings) |
| BLE mesh: discovery (scan)         |   ✅    |   ✅ macOS (CoreBluetooth) + Linux (BlueZ) |
| BLE mesh: advertise + GATT server  |   ✅    |   ✅ macOS only, ⚪️ not implemented on Linux (Windows: crate does not build) |
| BLE mesh: messaging (DMs/broadcast) |   ✅    |   ⚪️ next stage (Noise-over-GATT transport) |
| Unify nearby payments (BLE)         |   ✅    |   ⚪️ not yet (same bridge, later) |
| Lightning wallet (⚡PAY)            |   ✅ (Breez) | ⚪️ unavailable (no desktop Breez build yet) |

Desktop covers the entire **internet-backed** surface — exactly the slice that
interops cross-platform over the same Nostr relays — plus **BLE discovery**.

- **BLE mesh** was never a hardware or Compose limitation — it's a JVM-library
  gap (no pure-JVM BLE library). The desktop drives Bluetooth through a small
  native bridge, **`core/sonar-ble`**, loaded over JNA exactly like the Rust core,
  in two roles:
  - **central/scan** (`btleplug` → CoreBluetooth/BlueZ) — the radar shows nearby
    bitchat-mesh phones. Works on **macOS and Linux**;
  - **peripheral/advertise + GATT server** (`bluster`) — the desktop advertises
    the bitchat service and, when a phone subscribes, serves a signed **announce**
    built by the same `meshBuildAnnounce` Rust function the phones use, so the
    phone shows the desktop as a named peer. **macOS only**. The notify /
    write-drain side channel this role is built on is a Sonar patch that exists
    solely in bluster's CoreBluetooth backend. On Linux `sonar_ble_advertising_supported()`
    returns false, the host skips the advertise path, and only the scan radar runs. Bringing it to BlueZ means
    wiring bluster's cross-platform `gatt::event` channel, tracked separately.

  What this means on Linux in practice: a nearby phone with the mesh screen open
  **is** discovered, with live signal strength. But a peer's *name* comes from
  the signed announce the phone writes over GATT, which needs the peripheral
  role, so the radar shows an unnamed "nearby phone" and mesh DMs do not form.
  macOS gets named peers and DMs; Linux gets presence only.

  (`bluster` is vendored + patched; see
  `core/sonar-ble/vendor/bluster/SONAR_PATCH.md`.) Still to come:
  the **Noise-over-GATT message transport** (encrypted DMs/broadcast over the
  link) — at which point the desktop joins the mesh fully.
  - **macOS permission**: BLE needs the Bluetooth grant. The packaged `.app`
    carries `NSBluetoothAlwaysUsageDescription` and prompts on first use. With
    `./gradlew :composeApp:run` (no `.app` bundle) macOS can't prompt, so scanning
    only returns results if the launching terminal already has the Bluetooth grant.
- **Location channels**: a desktop has no GPS, so "Around you" is empty by
  default. Enable **Settings → Approximate location** to resolve coarse
  city/region/country geohash channels from your IP (opt-in; sends your IP to a
  geolocation service). Or just join any geohash channel via Search.
- The **Lightning wallet** is a documented follow-up (a JVM Breez build, or an
  LDK/CLN/LND bridge).

## Build & run — Desktop

On Linux, install the BlueZ build deps first (the BLE bridge links `libdbus-sys`
through pkg-config): `sudo apt-get install libdbus-1-dev pkg-config`. Without
them, build with `SONAR_SKIP_BLE=1` to skip the bridge; the app then runs
internet-only.

```bash
# 1. Build the Rust core + BLE bridge for the host (one time, or after a change).
#    Produces jvmMain/resources/<jna-prefix>/{libsonar_ffi,libsonar_ble}.<ext>
#    + the UniFFI Kotlin bindings.
core/build-desktop.sh

# 2a. Quick run (no BLE — see the permission note below).
cd apps/sonar
./gradlew :composeApp:run

# 2b. Build the installable app — REQUIRED for Bluetooth to work.
#     The .app carries NSBluetoothAlwaysUsageDescription + the Bluetooth
#     entitlement, so macOS grants BLE. Output: build/compose/binaries/main/app/Sonar.app
./gradlew :composeApp:createDistributable          # the .app
./gradlew :composeApp:packageDistributionForCurrentOS   # a .dmg/.msi/.deb
cp -R composeApp/build/compose/binaries/main/app/Sonar.app /Applications/
open /Applications/Sonar.app
```

Desktop data (identity, encrypted Marmot DB, transcripts, prefs) lives under the
OS app-data dir: `~/Library/Application Support/Sonar` on macOS,
`$XDG_DATA_HOME/Sonar` (default `~/.local/share/Sonar`) on Linux, and
`%APPDATA%\Sonar` on Windows.

### Seeing mesh peers on the radar

The desktop discovers nearby bitchat-mesh phones over BLE. Two conditions:

1. **Run the packaged `.app`** (not `gradle run`) so macOS grants Bluetooth — the
   raw `java` process from `gradle run` has no `.app` bundle, so macOS can't grant
   it. On first launch, approve the Bluetooth prompt (or System Settings → Privacy
   & Security → Bluetooth → Sonar).
2. **Keep the phone's Sonar/bitchat app in the foreground** — iOS stops BLE mesh
   advertising when the app is backgrounded, so a backgrounded phone is invisible.

Then click **Sonar** in the sidebar → the phone appears as a node on the radar
(and the sidebar shows "N people in range"). Set `SONAR_BLE_DEBUG=1` to trace the
scan to `$XDG_STATE_HOME/sonar/sonar-ble.log` (default `~/.local/state/sonar/`
on Linux, `~/Library/Logs/sonar/` on macOS). Device addresses and names are
never written there.

## Build & run — Android

Full guide (secrets, ABIs, release APKs, pitfalls):
[`docs/ANDROID-BUILD.md`](../../docs/ANDROID-BUILD.md).

```bash
# Gradle runs :composeApp:buildAndroidRustCore first, generating Rust .so files
# and UniFFI bindings under androidMain from core/build-android.sh.
cd apps/sonar

# Debug install (arm64-v8a only — modern phone or arm64 emulator)
./gradlew :composeApp:installDebug

# Release APK — phones only (arm64-v8a + armeabi-v7a)
./gradlew :composeApp:assembleRelease

# Universal APK — phones + x86/x86_64 emulators
./gradlew :composeApp:assembleRelease -Psonar.universalApk=true

# Optional manual core rebuild:
ANDROID_NDK_HOME=/path/to/ndk ../../core/build-android.sh
```

Put `sdk.dir` and `breez.apiKey` in gitignored `local.properties` (or export
`BREEZ_API_KEY`). Debug may omit the key (Settings → Unavailable); release
`assembleRelease` / `bundleRelease` refuse without it. Release APKs are
unsigned unless you configure signing.

## Tests

```bash
./gradlew :composeApp:jvmTest   # commonTest + the desktop FFI smoke test
```

`DesktopFfiSmokeTest` proves the Rust core loads and runs through JNA on the host
(Nostr identity round-trip + a full Noise XX handshake) with no network — the key
regression guard for the desktop target.
