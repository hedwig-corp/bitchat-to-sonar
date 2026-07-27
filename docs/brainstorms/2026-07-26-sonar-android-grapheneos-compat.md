# GrapheneOS compatibility for Sonar Android (push + native hardening)

Date: 2026-07-26
Status: brainstorm — no code changed

## Goal

Make the Compose Android app a first-class GrapheneOS citizen: fully usable and
correctly wakeable both **with** sandboxed Google Play (FCM) and **fully
degoogled** (no Play Services at all, push via UnifiedPush), and verified
against GrapheneOS's native hardening on a real attached device.

## Grounding — what the code does today

| Fact | Where |
| --- | --- |
| FCM token fetched with no Play-Services availability check; failure is a `Log.w` and push dies silently | [SonarPushRegistration.kt:85](apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/push/SonarPushRegistration.kt:85) |
| MIP-05 platform byte accepts only `"apns"` / `"fcm"` | [push.rs:53](core/sonar-core/src/push.rs:53) |
| Transponder is an **upstream image**, not our source | `deploy/compose.yml:25` → `ghcr.io/marmot-protocol/transponder:0.1.0` |
| Breez NDS is also **upstream** (`breez/notify` pinned at `54b1cdc4ae29`), we only build a container | `deploy/breez-nds/Dockerfile` |
| Breez webhook we register with the swap server is `https://<nds>/api/v1/notify?platform=android&token=<fcm>` | [SonarPushRegistration.kt:287](apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/push/SonarPushRegistration.kt:287) |
| No `WorkManager` / `AlarmManager` / persistent-socket fallback anywhere in `androidMain` | grep: zero hits |
| `SonarPushProcessingService` (dataSync FG service) only ever starts from an FCM message | `AndroidManifest.xml` |
| google-services plugin applied by default; `-Psonar.skipGoogleServices=true` already opts out | `composeApp/build.gradle.kts:19-23` |
| `core/build-android.sh` auto-picks the **highest installed NDK**, no pinned version, no `max-page-size` link arg | `core/build-android.sh:29-39, 77` |
| AGP 8.7.3, minSdk 26, targetSdk 35 | `apps/sonar/gradle/libs.versions.toml` |

Net today on a degoogled GrapheneOS phone: the app installs and runs, BLE mesh
and foreground relay sync work, and **background message delivery and offline
BOLT12 receive are both completely dead** — with no UI saying so.

## Constraints

- Must not regress the Play-Services path (Zapstore + GitHub APKs serve both
  audiences from the same artifact today).
- Account Key Durability Rule: nothing here may create a path where a missing
  Play Services, a revoked INTERNET permission, or a BFU (post-auto-reboot)
  state looks like a fresh account.
- Never Uninstall Device Apps Rule: all device testing is `adb install -r` /
  `installDebug` over the existing app. Use a **secondary GrapheneOS user
  profile** for any fresh-install scenario.
- Cross-Platform Feature Rule: UnifiedPush is Android-only by nature; the iOS
  gap must be documented explicitly, not silently skipped. (Also: standing
  instruction is Android/Rust-core only for now.)
- The two long poles are **not in this repo**: `marmot-protocol/transponder`
  and `breez/notify`.
- Signal-First: Signal-Android's no-Play "websocket mode" and its
  `PlayServicesUtil` / `FcmFetchManager` degradation path are the reference for
  the detect-and-degrade shape.

## Non-goals

- Building our own push server. Transponder stays upstream.
- Removing Firebase from the default build.
- iOS changes.
- Shipping a second APK per push transport (see Approach B — rejected).
- Making Tor/Arti the default transport.

## Success criteria

1. On GrapheneOS **with** sandboxed Play: unchanged behaviour, plus a Settings
   diagnostic showing "push transport: FCM, registered".
2. On GrapheneOS **without** Play: user picks/has a UnifiedPush distributor
   (ntfy), Sonar registers, and a message sent while the app is force-stopped
   produces a notification. Offline BOLT12 receive works while killed.
3. Without Play **and** without any distributor: no crash, no silent failure —
   an explicit in-app state ("no background delivery — install ntfy") and
   foreground sync still works.
4. Every bundled `.so` has 16 KB-aligned LOAD segments; app survives
   hardened_malloc and MTE-enabled runs across Arti bootstrap, SQLCipher open,
   Breez node start, BLE mesh, and media send.
5. INTERNET permission revoked → clear offline UI, BLE mesh still works, no
   hang, no account reset.
6. Post-auto-reboot BFU → app recovers on unlock with the same identity.

## Approaches

### A. One APK, runtime dual transport (recommended)

Keep Firebase in the build. At registration time detect
`GoogleApiAvailability.isGooglePlayServicesAvailable()`; on `SUCCESS` use FCM as
today, otherwise fall back to a UnifiedPush distributor discovered via the
UnifiedPush Android connector library. Both paths converge on the same
`SonarCore.registerPushToken(platform, token)` call — the "token" for
UnifiedPush being the distributor-issued endpoint URL.

- Affected: `push/SonarPushRegistration.kt`, new `push/SonarUnifiedPushReceiver.kt`,
  `push/SonarPushPrefs.kt`, `AndroidManifest.xml`, `composeApp/build.gradle.kts`,
  `core/sonar-core/src/push.rs` (new platform byte), the UniFFI
  `register_push_token` signature, Settings diagnostics UI.
- Gains: single artifact for Zapstore/GitHub; degoogled users are first-class;
  smallest divergence from the existing code shape.
- Costs: Firebase stays a dependency in the degoogled APK (dead weight, and a
  purity objection from that audience); endpoint URLs are longer than FCM
  tokens — check against `TOKEN_PLAINTEXT_SIZE - 3` in `push.rs`.
- Effort: **M** in-app, **L** counting upstream.

### B. Product flavors (`google` / `foss`)

Two build flavors; `foss` drops Firebase entirely and compiles only the
UnifiedPush path.

- Gains: a genuinely Google-free binary, which is what the GrapheneOS/F-Droid
  audience actually asks for; smaller APK.
- Costs: doubles the release/Zapstore matrix (`docs/ZAPSTORE.md`,
  `scripts/zapstore-publish.sh`, website download link), doubles CI, and a
  sandboxed-Play user who installs `foss` gets the worse transport for no
  reason. Flavor-specific source sets are exactly the kind of seam that lets a
  fix land on one side only.
- Effort: **L**. Rejected for v1; revisit only if F-Droid inclusion demands it.

### C. Transport-agnostic push provider abstraction

Introduce a `PushTransport` interface (`register()`, `onEndpoint()`,
`onMessage()`) with FCM, UnifiedPush and a persistent-foreground-service
implementation behind it, and make MIP-05's platform field an open enum rather
than a two-value switch.

- Gains: the foreground-service fallback (Signal's websocket mode) drops in
  later without touching call sites; the same seam serves desktop.
- Costs: over-built for two transports; the real blocker is upstream
  transponder support, which no abstraction removes.
- Effort: **L**. Take the *shape* (open platform enum in `push.rs`) without the
  full interface.

## Recommendation

**Approach A**, with C's open-platform-enum shape in `push.rs`, sequenced so
that the parts we own land before the upstream dependency.

The upstream transponder is the critical path and we do not control its
schedule. Sequence accordingly:

**Phase 0 — device truth (do first, it may change everything).**
Run the native-hardening checklist below on the attached GrapheneOS phone with
the current build. If Arti or the Breez natives abort under hardened_malloc, or
a `.so` is 4 KB-aligned on a 16 KB kernel, that is a higher-severity bug than
push and reorders the whole plan.

**Phase 1 — stop lying to degoogled users (app-only, ships immediately).**
Add `GoogleApiAvailability` detection, surface push transport + registration
state in Settings → Diagnostics, and make the "no background delivery" case an
explicit user-visible state instead of a `Log.w`. No protocol change. This
alone converts a silent failure into an honest one.

**Phase 2 — Breez offline receive without Google (no upstream needed).**
This is the sleeper win: the URL we hand the swap server is just an HTTPS
webhook that our NDS translates into FCM. A UnifiedPush endpoint **is** an
HTTPS POST target. So on the degoogled path we can register the UnifiedPush
endpoint directly and bypass NDS entirely — no `breez/notify` change at all.
Two things to settle: whether the raw Boltz payload is enough for the receiver
to drive `WalletBridge` without NDS's reshaping, and the privacy trade (Boltz
learns the ntfy endpoint instead of learning the FCM token — arguably neutral,
but self-hosting ntfy makes it strictly better).

**Phase 3 — MIP-05 platform byte + upstream transponder.**
Add `PLATFORM_UNIFIEDPUSH` alongside apns/fcm in `push.rs`, widen the
`register_push_token` FFI, then open the transponder PR/issue to teach it to
POST to an endpoint URL for that platform byte. Chat/call wakeups on degoogled
devices unblock only when that merges and we redeploy.

**Phase 4 — Android app UnifiedPush receiver** wired to the same
`SonarPushProcessingService` drain path FCM already uses.

### Shippable scope for the first PR (what /ship implements)

Everything in this repo that does not block on the upstream transponder merge
or on physical-device results:

1. **Play detection + honest degrade (Phase 1)** — `GoogleApiAvailability`
   check before any `FirebaseMessaging` call; push-transport state machine
   (`FCM` / `UNIFIEDPUSH` / `NONE`) surfaced in Settings → Diagnostics; the
   `NONE` state renders explicit "no background delivery — install a
   UnifiedPush distributor (e.g. ntfy)" copy instead of a silent `Log.w`.
2. **Core open-platform enum (Phase 3 groundwork)** — `PLATFORM_UNIFIEDPUSH =
   0x03` in `push.rs`, accepted by `platform_byte()`, covered by unit tests;
   FFI doc updated. Wire-format additive; existing apns/fcm bytes unchanged.
3. **UnifiedPush connector (Phase 4, app side)** — UnifiedPush `connector`
   AAR, distributor discovery, endpoint registration through the same
   `SonarCore.registerPushToken("unifiedpush", endpoint)` call, receiver
   funneling into `SonarPushProcessingService`. Fully functional the moment
   the deployed transponder understands platform 0x03; until then it registers
   and the diagnostics row says "awaiting server support".
4. **Static 16 KB alignment check** — pin an NDK floor +
   `max-page-size=16384` link arg in `core/build-android.sh`, plus a
   `llvm-readelf` CI-runnable script over the APK's `jniLibs`.
5. **Notifications documentation** — new `docs/NOTIFICATIONS-MATRIX.md`
   (see Deliverables) describing how notifications work on every supported
   device, including the GrapheneOS paths.

Explicitly out of the first PR (tracked gaps in the PR description):
upstream `marmot-protocol/transponder` platform-0x03 support (issue/PR to be
filed with the prepared payload spec), Breez NDS-bypass for degoogled offline
receive (needs a payload experiment), the on-device hardened_malloc/MTE pass
(needs the attached phone), and iOS (no work per standing instruction; iOS is
APNs-only by platform design — documented, not a silent skip).

### Deliverables

- Code per shippable scope above.
- `docs/NOTIFICATIONS-MATRIX.md`: one page, per-device matrix — iOS/macOS
  (APNs + NSE, Breez NDS silent path), Android with Play (FCM), Android
  degoogled/GrapheneOS (UnifiedPush + current limitations), desktop
  (local/tray only, issue #54) — with pointers into
  `docs/SONAR-NOTIFICATIONS.md` for the deep architecture.
- `docs/GRAPHENEOS.md` seeded with the support matrix + device checklist
  (results filled in after the Phase 0 device pass).

Risk to accept explicitly: if Phase 3 stalls upstream, degoogled users have
working offline payments (Phase 2) and honest UI (Phase 1) but still no chat
wakeups. The escape hatch is the persistent-foreground-service relay socket —
purely local, no upstream — which is worth keeping on the shelf as the
contingency even though it was not the chosen primary.

## Native hardening checklist (device pass, Phase 0)

Device rules: `adb install -r` / `./gradlew :composeApp:installDebug` only.
Never uninstall. Use a **secondary GrapheneOS user profile** for fresh-install
scenarios so the real account key is never at risk.

1. **16 KB page size.** `llvm-readelf -lW` every `.so` in the APK
   (`libsonarffi.so`, Arti/OpenSSL deps, SQLCipher, Breez, oboe); every `LOAD`
   segment must have align ≥ `0x4000`. Fix by pinning NDK r27+ in
   `core/build-android.sh` (it currently takes whatever is newest) and adding
   `-C link-arg=-Wl,-z,max-page-size=16384`. Non-determinism here is its own
   bug — two machines can produce differently-aligned artifacts today.
2. **hardened_malloc.** Exercise Arti/Tor bootstrap, SQLCipher DB open, Breez
   node start, BLE mesh scan/advertise/GATT, media send, call setup. Watch
   `logcat` for `SIGABRT` with hardened_malloc fatal strings; pull tombstones.
3. **MTE.** GrapheneOS per-app exploit-protection → force Memory Tagging on,
   repeat step 2. Look for `SEGV_MTESERR` / `SEGV_MTEAERR`.
4. **Network permission revoked** (GrapheneOS makes INTERNET revocable): must
   show a clear offline state, must not hang a relay connect forever, BLE mesh
   must keep working, and it must **not** look like a missing account.
5. **Sandboxed Play in a different profile** than Sonar → confirm the app
   detects "no Play" correctly rather than half-registering.
6. **Auto-reboot / BFU.** After the 18 h auto-reboot, verify identity, DB key
   and onboarding flag all survive the locked-then-unlocked transition — the
   Account Key Durability Rule's highest-risk scenario on this OS.
7. **Storage Scopes / photo picker** for media send.
8. **Battery.** With sandboxed Play, Play Services is an ordinary app subject to
   doze; measure FCM latency and document the "exempt Play Services and Sonar
   from battery optimization" guidance.

Deliverable: `docs/GRAPHENEOS.md` with findings, the support matrix, and the
user-facing setup guide.

## Open questions

- Which UnifiedPush distributor do we recommend/test — ntfy on
  `ntfy.sh`, or a self-hosted one alongside the existing relay/NDS stack? The
  privacy story is much better self-hosted, and we already run infra.
- ~~Does the encrypted MIP-05 token blob have room for a full endpoint URL?~~
  **Resolved:** `TOKEN_PLAINTEXT_SIZE = 1024` → up to 1021 token bytes; a
  UnifiedPush endpoint URL (~100–200 chars) fits raw, no indirection needed.
  The FFI `register_push_token(platform: String, …)` is string-typed, so
  adding `"unifiedpush"` is additive with no UniFFI signature break.
- Is `breez/notify` genuinely bypassable for the degoogled path, or does the
  app depend on NDS reshaping the Boltz payload? Determines whether Phase 2 is
  app-only.
- What is the actual GrapheneOS default for per-app MTE on Pixel 8+? Test on
  device rather than trusting docs — it decides whether step 3 is a
  must-pass or a nice-to-have.
- Does the transponder maintainer want a generic `webhook` platform byte
  (useful beyond UnifiedPush) or a UnifiedPush-specific one? Ask before
  writing the PR.
- Should the persistent-foreground-service fallback ship as a user-selectable
  "battery-hungry reliable mode" regardless, as Signal does?

## Next

`/ship --from-brainstorm docs/brainstorms/2026-07-26-sonar-android-grapheneos-compat.md`
— but start with Phase 0 on the attached device; its findings may reorder the rest.
