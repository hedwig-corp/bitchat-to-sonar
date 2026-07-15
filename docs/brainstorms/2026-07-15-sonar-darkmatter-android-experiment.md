# Sonar Darkmatter Android Experiment

## Clarified Problem Statement

**Goal:** Ship a separately installable Android app named **Sonar Darkmatter**, built against the stable Darkmatter MDK `v0.9.4` release, with its own runtime identity and storage and its own Zapstore listing, without changing or risking the existing Sonar installation.

### Decisions already made

- Target the released MDK `v0.9.4`, not upstream `master`. Resolve and lock the release to its immutable commit (`e391adc133a9b60e420da7a0446f014a180ac8d2`) for reproducible builds.
- Sonar Darkmatter is an experimental app installed alongside Sonar, not an upgrade or replacement.
- Runtime state is isolated: no shared account, database, preferences, wallet state, files, push token, notification namespace, or Android Keystore entries.
- Publish it as a new Android app and a new Zapstore entry.

### Context

The current Sonar Rust workspace pins the legacy MDK `0.8.0` API at `e8cd584` in `core/Cargo.toml`. Darkmatter `v0.9.4` is not a drop-in update: upstream replaced the old `mdk-core` / `mdk-storage-*` surface with a workspace organized around `cgka-engine`, `cgka-session`, `storage-sqlite`, `transport-nostr-*`, `marmot-account`, `marmot-app`, and `marmot-uniffi`. The work therefore needs a new adapter boundary and migration of Sonar's Marmot behavior, not merely a Cargo revision change.

The existing Android app is `chat.bitchat.sonar` in `apps/sonar/composeApp/build.gradle.kts`; it already has signed APK and Zapstore tooling through `scripts/zapstore-publish.sh` and `zapstore.yaml`.

### Constraints

- Keep the production Sonar package, legacy MDK dependency, data, signing configuration, and Zapstore listing unchanged.
- Use a distinct application ID; proposed default: `chat.bitchat.sonar.darkmatter`.
- Use a visibly distinct launcher name and icon treatment so testers cannot confuse the experimental app with production Sonar.
- Start with fresh onboarding and fresh app-local secrets. Importing Sonar's `nsec`, message database, or wallet state is excluded from this experiment.
- Use a separate Android signing key/certificate and separate Firebase Android app configuration if push is enabled. Secrets remain gitignored or in CI.
- Preserve local-first behavior: chat list/transcript paint from bounded local storage; relay connection and repair remain background work.
- Android is the initial experimental surface. Document the native Apple app as an explicit platform gap, with the follow-up being evaluation after the Darkmatter adapter and storage behavior are proven.
- Treat interoperability as Darkmatter-only unless tests demonstrate compatibility with legacy Sonar/White Noise wire data.

### Non-goals

- Upgrading or replacing the current Sonar app.
- Migrating existing legacy-MDK groups or transcripts.
- Sharing runtime state between Sonar and Sonar Darkmatter.
- Tracking unreleased MDK `master`.
- Shipping an iOS/macOS Darkmatter binary in the first experiment.
- Achieving every existing Sonar feature before the first test release; unsupported features must be clearly identified rather than silently sharing legacy state.

### Success criteria

- Both Sonar and Sonar Darkmatter install and launch simultaneously on one Android device.
- Android reports distinct package IDs and data directories, and clearing/uninstalling either app does not alter the other.
- Sonar Darkmatter generates and retains its own identity and encrypted database across restarts without reading Sonar's identity or database.
- The Rust integration builds from MDK `v0.9.4`'s locked commit and exposes the minimum app operations needed for onboarding, group discovery/creation, send, receive, local transcript paging, and restart recovery.
- Two Darkmatter-compatible test clients can create or accept a conversation and exchange messages after process restart.
- Chat opening remains local-first and bounded; network sync does not gate first paint.
- A release-signed phone APK (arm64-v8a and armeabi-v7a) passes Android signature verification and can be installed on a clean device.
- A new Zapstore configuration publishes Sonar Darkmatter under its distinct package ID, metadata, icon, artifact pattern, and signing-certificate identity link.
- Release documentation records the Android-only experimental scope and the Apple follow-up gap.

## Approaches Considered

### Approach A: Separate Android flavor plus dedicated Darkmatter core adapter

- **Sketch:** Add a `darkmatter` Android product flavor with its own application ID, resources, manifest overlays, configuration, and generated native artifact. Keep the Compose UI shared, but put the new protocol integration behind a dedicated Rust crate/FFI adapter so legacy Sonar continues compiling against its current core.
- **Affected files/modules:** `apps/sonar/composeApp/build.gradle.kts`, new `src/darkmatter/` resources/manifest, `core/Cargo.toml`, new Darkmatter core/FFI crate(s), `core/build-android.sh`, `SonarCore.android.kt`, a new `zapstore-darkmatter.yaml`, and variant-aware Zapstore publishing support.
- **Tradeoffs:** Best balance of runtime isolation and UI reuse; one repository can build and compare both apps. Variant-aware native builds and maintaining two protocol adapters add Gradle/Cargo complexity, and shared UI changes must continue compiling for both backends.
- **Effort:** Large.

### Approach B: Dedicated Android application module

- **Sketch:** Create a separate `sonarDarkmatterApp` Gradle module and separate Rust bridge, extracting reusable Compose UI into shared library modules where practical. The new module owns its package, resources, dependencies, build tasks, and release pipeline.
- **Affected files/modules:** `apps/sonar/settings.gradle.kts`, a new app module, extracted shared Compose modules, new Rust core/FFI crate(s), Android build scripts, and independent Zapstore/release files.
- **Tradeoffs:** Clearest build-time boundary and lowest risk of accidentally packaging legacy state/configuration. It requires an up-front module split and more build maintenance, so reaching the first APK is slower.
- **Effort:** Large to extra-large.

### Approach C: Long-lived branch or repository fork

- **Sketch:** Copy the current app into an experimental branch/repository, replace the legacy core with the Darkmatter implementation, rename the package, and publish from that line independently.
- **Affected files/modules:** Nearly the full Rust core, Compose app, release scripts, and repository metadata in the fork.
- **Tradeoffs:** Strongest organizational isolation and initially straightforward experimentation. It duplicates fixes, makes UI/security parity drift likely, and creates a costly future merge path; repository separation alone does not improve Android sandbox isolation beyond a distinct package ID.
- **Effort:** Medium initially, very large over time.

## Recommendation

**Implementation refinement after inspecting the released APIs:** choose **Approach B: a dedicated Android application module**. MDK v0.9.4 already provides a complete Android MarmotKit UniFFI runtime, including SQLCipher, Android Keystore integration, bounded chat/timeline projections, subscriptions, and its own build script. Consuming that release in an independent module provides a stronger guarantee that the experiment cannot package Sonar's legacy FFI, wallet, Firebase configuration, or app-local state.

Implement it in release gates: first consume and verify the official `v0.9.4` binding; then produce a side-by-side debug APK with local-first pending conversation/outbox behavior; then verify Darkmatter message/restart behavior; finally add independent signing and the new Zapstore listing.

## Open Questions (non-blocking defaults proposed)

- **Final application ID:** default to `chat.bitchat.sonar.darkmatter`.
- **Display name:** default to `Sonar Darkmatter`.
- **Version line:** start independently at `0.1.0-darkmatter.1` / Android `versionCode = 1`.
- **Visual distinction:** reuse the Sonar icon geometry with a clearly different palette and an experimental badge.
- **Push/wallet scope for the first release:** default to messaging-only until independent FCM and wallet configuration have been explicitly validated; do not fall back to Sonar's local secrets.

## Next

Run `/ship --from-brainstorm docs/brainstorms/2026-07-15-sonar-darkmatter-android-experiment.md` to implement and publish through the normal reviewed release flow, or request a plan-only pass first.
