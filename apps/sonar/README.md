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
| BLE mesh (nearby radar, mesh DMs)   |   ✅    |   ⚪️ not yet (needs a native BLE bridge) |
| Unify nearby payments (BLE)         |   ✅    |   ⚪️ unavailable |
| Lightning wallet (⚡PAY)            |   ✅ (Breez) | ⚪️ unavailable (no desktop Breez build yet) |

Desktop covers the entire **internet-backed** surface — exactly the slice that
interops cross-platform over the same Nostr relays.

- **Location channels**: a desktop has no GPS, so "Around you" is empty by
  default. Enable **Settings → Approximate location** to resolve coarse
  city/region/country geohash channels from your IP (opt-in; sends your IP to a
  geolocation service). Or just join any geohash channel via Search.
- **BLE mesh** is not a hardware or Compose limitation — it's a JVM-library gap.
  The bitchat mesh needs the BLE *peripheral* (GATT-advertising) role, and no
  pure-JVM library provides it. macOS CoreBluetooth (`CBPeripheralManager`,
  available since 10.9) and Linux BlueZ both support it, so it's reachable as a
  follow-up via a small native shim over the existing FFI (Swift/Obj-C, or a Rust
  crate like `bluster`) — the same bridge pattern the Rust core already uses.
  (The original bitchat ships its mesh natively on the Mac App Store, confirming
  the role works on Mac.)
- The **Lightning wallet** is a documented follow-up (a JVM Breez build, or an
  LDK/CLN/LND bridge).

## Build & run — Desktop

```bash
# 1. Build the Rust core for the host (one time, or after core changes).
#    Produces jvmMain/resources/<jna-prefix>/libsonar_ffi.<ext> + UniFFI bindings.
core/build-desktop.sh

# 2. Run the app.
cd apps/sonar
./gradlew :composeApp:run

# Package a native installer (.dmg / .msi / .deb):
./gradlew :composeApp:packageDistributionForCurrentOS
```

Desktop data (identity, encrypted Marmot DB, transcripts, prefs) lives under the
OS app-data dir, e.g. `~/Library/Application Support/Sonar` on macOS.

## Build & run — Android

```bash
ANDROID_NDK_HOME=/path/to/ndk core/build-android.sh   # Rust core .so + bindings
cd apps/sonar
./gradlew :composeApp:installDebug
```

## Tests

```bash
./gradlew :composeApp:jvmTest   # commonTest + the desktop FFI smoke test
```

`DesktopFfiSmokeTest` proves the Rust core loads and runs through JNA on the host
(Nostr identity round-trip + a full Noise XX handshake) with no network — the key
regression guard for the desktop target.
