# Repository Guidance

## Cross-Platform Feature Rule

Sonar is a multi-platform product. New user-facing features must be designed and implemented for every supported app surface unless a platform limitation is documented in the change itself.

When adding or changing a feature, cover the native Apple app (`ios/`) and the Compose Multiplatform app (`apps/sonar/`) together. If a capability cannot ship on one platform in the same change, leave an explicit tracked gap with the platform, reason, and follow-up path.

## Signal-Comparable Performance Rule

Conversation and transcript changes must preserve Signal-comparable local-first performance. Opening an existing chat must paint from local storage first and must not wait on relay/server sync, full-history scans, or unrelated groups before first paint. If a change can make chat opening, sending, or scrolling meaningfully slower than Signal-style local database windowing, design a bounded local page/window path, move sync to the background, and document any platform gap with a follow-up path.

## Signal-Style Conversation Design Notes

Signal treats the local database as the chat state. Network receive/send/sync paths write into local storage first, then the chat list and transcript UI react to local database invalidation. Android pages local conversation rows from `ThreadTable` through `ConversationListDataSource` with a small paging window; iOS builds chat-list render state from local thread IDs through `CLVLoader` and caches row view models/content. Sonar conversation work should follow that model: maintain core-owned local conversation summaries ordered by latest message, hydrate visible chat rows from bounded local pages, open transcripts from bounded local message windows, and run relay sync only as a background database updater.

## Local Secrets Rule

Do not commit payment, wallet, relay, signing, or API secrets. The Breez wallet key must stay in gitignored local configuration (`ios/Configs/Local.xcconfig` with `BREEZ_API_KEY = ...`) or an equivalent CI secret. When creating a new workspace/worktree or rebuilding for device testing, preserve the local secret by recreating/copying the gitignored config or passing the key through the build environment; verify presence without printing the value.

## Cursor Cloud specific instructions

The Cloud Agent VM is **Linux x86_64** — the native Apple app (`ios/`) and the
root `Justfile` need macOS/Xcode and are **out of scope here**. The Linux-runnable
surfaces are the Rust core (`core/`), the Compose app's **JVM/Desktop** target
(`apps/sonar/`), the web landing page (`web/`), and the `handle-registrar`
service (`services/`). Standard commands are already documented — see `README.md`,
`docs/ANDROID-BUILD.md`, and the CI in `.github/workflows/{core-tests,compose-tests,pages}.yml`;
prefer those over re-deriving commands.

Toolchains are baked into the VM snapshot by the environment setup, not the
update script: Rust stable (`rustup`), full JDK 17, Node 22, and an Android SDK
(platform/build-tools 35) under `$HOME/android-sdk`. `JAVA_HOME` (JDK 17) and
`ANDROID_HOME` are exported from the agent's `~/.bashrc`. The update script only
refreshes project dependencies (`npm ci`, `cargo fetch`) and re-creates the
gitignored `apps/sonar/local.properties` (`sdk.dir`) if missing.

Non-obvious gotchas discovered during setup:

- **Compose needs a NON-headless JDK.** `getString()` in Compose resource
  loading initializes AWT, so JVM unit tests and the desktop app throw
  `java.awt.HeadlessException` under a `-headless` JDK. Use the full
  `openjdk-17-jdk` (installed), not `openjdk-17-jdk-headless`.
- **`:composeApp:jvmTest` needs a display.** Run it under xvfb like CI:
  `xvfb-run -a ./gradlew :composeApp:jvmTest` (from `apps/sonar`). A Gradle
  **daemon** started without a display makes forked test workers headless even
  under `xvfb-run`; if you see `HeadlessException`, run `./gradlew --stop` first,
  then a single `xvfb-run -a ./gradlew …`.
- **Running the desktop app:** `DISPLAY=:1 ./gradlew :composeApp:run` (from
  `apps/sonar`) — `:1` is the real XFCE display used for GUI/computer-use. Skiko
  logs `Cannot create Linux GL context` and falls back to software rendering;
  that warning is expected and harmless. On Linux desktop, BLE is scan-only and
  the Lightning wallet is unavailable (documented in `apps/sonar/README.md`).
- **Native lib generation:** Gradle wires `core/build-desktop.sh` via
  `:composeApp:buildDesktopRustCore` (host `libsonar_ffi.so` + `libsonar_ble.so`
  + UniFFI Kotlin bindings, and it fetches a pinned Breez native lib over the
  network). Re-run `core/build-desktop.sh` manually after `core/` changes if the
  desktop app doesn't pick them up.
- **Android native build is NOT set up.** The JVM/desktop path needs no NDK, but
  `:composeApp:installDebug` / `assembleRelease` / `buildAndroidRustCore` require
  NDK r27d + `cargo-ndk` + `uniffi` CLI (see `compose-tests.yml`
  `android-device-test`), which are not installed. Install them if you need
  Android APKs.
- **Wallet island:** `core/sonar-wallet-breez` is excluded from the core
  workspace and needs `protoc` (installed); test it with `cargo test --locked`
  in that directory (CI: `core-tests.yml` `wallet-breez-island`).
- Without a `breez.apiKey` the app builds and chat works; the wallet shows
  "Unavailable" (expected here). Never commit `local.properties` or the key.
