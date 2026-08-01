# Repository Guidance

## Cross-Platform Feature Rule

Sonar is a multi-platform product. New user-facing features must be designed and implemented for every supported app surface unless a platform limitation is documented in the change itself.

When adding or changing a feature, cover the native Apple app (`ios/`) and the Compose Multiplatform app (`apps/sonar/`) together. If a capability cannot ship on one platform in the same change, leave an explicit tracked gap with the platform, reason, and follow-up path.

## Signal-Comparable Performance Rule

Conversation and transcript changes must preserve Signal-comparable local-first performance. Opening an existing chat must paint from local storage first and must not wait on relay/server sync, full-history scans, or unrelated groups before first paint. If a change can make chat opening, sending, or scrolling meaningfully slower than Signal-style local database windowing, design a bounded local page/window path, move sync to the background, and document any platform gap with a follow-up path.

Marmot relay repair and missing-message resync must follow the same local-first
shape used by apps like XChat: never block chat open, chat list paint, sending,
or scrolling on relay connection, subscription repair, EOSE, full-history scans,
or watermark reconciliation. Load the locally stored transcript first, schedule
bounded repair on a background/IO path, write recovered events into local
storage, and let the UI update from database invalidation. For existing installs
that need missing-message recovery, derive the resync floor from the local
conversation transcript per chat, not from one global latest timestamp; a newer
local send in one chat must not advance another chat past missing peer messages.

## Signal-Style Conversation Design Notes

Before touching conversation, transcript, or unread code, read
[`docs/CHAT-TYPES.md`](docs/CHAT-TYPES.md): Sonar has two structurally different
chat kinds (pure White Noise/Marmot vs mesh-folded), with different id models
and staged hydration. Code that assumes one kind silently breaks the other —
always test both.

Signal treats the local database as the chat state. Network receive/send/sync paths write into local storage first, then the chat list and transcript UI react to local database invalidation. Android pages local conversation rows from `ThreadTable` through `ConversationListDataSource` with a small paging window; iOS builds chat-list render state from local thread IDs through `CLVLoader` and caches row view models/content. Sonar conversation work should follow that model: maintain core-owned local conversation summaries ordered by latest message, hydrate visible chat rows from bounded local pages, open transcripts from bounded local message windows, and run relay sync only as a background database updater.

## XChat-Style Chat Startup Rule

Starting or opening a chat by public key, creating a group, or accepting a group invite must never block on relay connect, key-package publish/fetch, profile/descriptor lookup, group creation, full-history sync, or any other network setup. Create a local pending conversation immediately, paint the transcript from local state, accept sends with local echoes and a bounded queue, and reconcile the pending row to the real White Noise/Marmot conversation when background setup completes. This should feel like xchat-style instant local chat creation: network work may update state later, but it must not gate first paint or basic typing/sending affordances.

## Signal-First Design Rule

Before implementing any well-known chat feature (media sending, reactions, read receipts, typing indicators, group management, voice/video calls, stories, disappearing messages, link previews, contact sharing, location sharing, stickers, etc.), study how Signal implements it in their open-source clients:

- **Signal-iOS**: https://github.com/signalapp/Signal-iOS
- **Signal-Android**: https://github.com/signalapp/Signal-Android

Check Signal's architecture for: data models, state lifecycle, memory management (file-backed vs in-memory), compression/processing timing (lazy vs eager), UI structure (navigation, editing, multi-item), cleanup paths (cancel, back, crash), and send pipeline (queued vs direct). Document in the PR description which Signal patterns were adopted, which were deferred (with tracked follow-ups), and why.

The goal is not to copy Signal — it is to avoid designing seams that make it expensive to reach Signal-quality later. A v1 can be minimal, but its data model and state flow should not preclude adding captions, multi-image, editing, or quality controls without a rewrite.

Concrete checklist for media features specifically (derived from Signal's `AttachmentApprovalViewController` + `SendMediaNavigationController`):

1. **Lazy finalization**: show full-quality preview; compress/re-encode only on send confirmation, not on pick
2. **File-backed large data**: for images >1MB, prefer file URLs / temp paths with ownership cleanup over holding raw bytes in reactive state
3. **Caption support**: design the preview data model with an optional message/caption field from day one, even if the UI doesn't expose it yet
4. **Multi-item ready**: use a list/collection for pending items, not a single nullable field, so multi-select doesn't require a model rewrite
5. **Cleanup on all exit paths**: cancel, back gesture, navigation pop, app backgrounding — verify each one releases resources

## Performance Analysis Rule

Sonar startup and relay-sync performance is measured with the cold-start
benchmark harness in `scripts/bench/` — see `docs/PERFORMANCE.md` for the full
method, markers, and baseline numbers. Use it whenever a change touches the
startup path or conversation open/send/sync, and when investigating "slow to
sync / slow to send" reports.

Device latency is only one benchmark axis. **Protocol scale** — the MLS/Marmot
group-size ceiling, welcome/commit growth, and concurrent-commit fork behavior —
is measured by the device-independent `sonar-sim` harness
(`cargo run -p sonar-sim --release -- group-scale …`); see
`docs/GROUP-SCALE-SIM.md` for method, the baseline table, and reproduce steps.
Run it whenever you **bump the MDK rev** or change the welcome/`create_group`/
`add_members` path, and diff the ceiling + welcome-size column against the
committed baseline — a moved ceiling after an MDK bump means the wire format
changed and can break White Noise interop. Assert only on structural outputs
(ceiling N, convergence, welcome bytes); wall-clock timings there are
machine-bound and report-only.

How to run the analysis:

1. Build the dependencies once: `core/build-ios.sh` (Rust core → `sonarffi.xcframework`, incl. the simulator slice), `cargo build -p sonar-cli --release` (headless counterparty), then `APP=$(scripts/bench/build-sim.sh)` (Debug, arm64, unsigned `.app`).
2. Faithful "existing account, cold process" run: `scripts/bench/provision-and-bench.sh --app "$APP" --runs 5 --msgs-per-run 3`. It seeds a real Marmot group via `sonar-cli` and pushes fresh messages before each run so every cold start exercises the real relay re-sync path (`woke=1`). For just the identity-independent phase breakdown, use `scripts/bench/cold-start-bench.sh --app "$APP" --runs 5`. To measure the REAL account on a physical iPhone (signed Debug build over the existing app, data preserved), use `scripts/bench/device-bench.sh` — this is where real pain points show up (e.g. blocking KeyPackage/profile publish on the cold-start critical path).
3. Read the per-phase min/median/max table. The app emits `SONAR_BENCH` markers (`t0_launch` → `t1_local_paint` → `t2_relay_connect_begin` → `t3_relay_connected` → `t3a_published` → `t3b_first_wake` → `t4_first_drain`) via `SecureLogger.info` (subsystem `chat.bitchat`, category `session`, DEBUG-only `%{public}@`); the harness parses them from the unified log.

Constraints and gotchas (all detailed in `docs/PERFORMANCE.md`): the build must be **Debug** (markers are private in Release) and **arm64-only** (Arti/sonarffi sim slices are arm64). CLI sim builds are unsigned and cannot get a Keychain entitlement for the `sh.hedwig.sonar` bundle id, so the benchmark path is **Keychain-independent** — adopt the `SONAR_BENCH_NSEC` identity and derive the DB key from it. All such hooks are `#if DEBUG` and gated on `SONAR_BENCH_NSEC`; never add a benchmark hook that changes behavior in Release. When reporting, quote `launch→t4`/`t0→t4` (cold → synced), `t2→t4` (relay path), `t3→t3a_publish_done` (publish latency — since #265 it runs CONCURRENTLY with the drain, and `t3→t3a` is only the dispatch), and `t3b→t4` (drain) against the baseline, and treat any regression that moves sync onto the critical path as a violation of the Signal-Comparable Performance Rule.

## Notification-Sync — Known Watch Items (verify with a real device push)

The notif-sync stack (#252 / #254 / #255) is unit-tested and code-reviewed, and cold-start / catch-up / local-first were device-validated on a real 43-group account. The forced-sync path, "Catching up…" UX, send-under-load, and push-while-refreshing could not be exercised via CLI (no background→foreground or real push-tap injection) and **must** be verified with a real APNs push on a physical device before trusting them in production:

- Forced-sync + "Catching up…" UX on a real device push (#262)
- Send-while-forced-sync contention on the serial engine queue (#263)
- Push arriving while `refreshAfterForeground` is in flight may wait a cycle (#264)
- Cold-start `t3→t4` dominated by `t3a_published` (KeyPackage/profile publish) (#265)

## Local Secrets Rule

Do not commit payment, wallet, relay, signing, or API secrets. The Breez wallet key must stay in gitignored local configuration (`ios/Configs/Local.xcconfig` with `BREEZ_API_KEY = ...`) or an equivalent CI secret. When creating a new workspace/worktree or rebuilding for device testing, preserve the local secret by recreating/copying the gitignored config or passing the key through the build environment; verify presence without printing the value.

## Account Key Durability Rule

The user's account identity key (`nsec` / `marmot-nsec`) is the app account. It
also controls wallet restore paths and encrypted chat database continuity, so the
app must never silently delete, replace, or regenerate it after onboarding.

Identity persistence changes must preserve these invariants on every supported
surface (`ios/` and `apps/sonar/`):

1. Never use delete-before-add for account keys. Save paths must update existing
   secrets in place, then add only when the item is genuinely missing.
2. Never treat keychain/keystore access errors, device-locked states, corrupt
   stored values, or access-group migration misses as permission to create a new
   account key after onboarding. Surface a restore/error path instead.
3. Mark onboarding complete only after the account key has been durably
   persisted. If persistence fails, keep the user on onboarding and do not set
   the onboarding flag.
4. If lightweight prefs such as onboarding flags are lost but a valid local
   account key still exists, recover the prefs from the key instead of showing a
   fresh-account path.
5. Wipe/reset flows must clear every storage location that can contain the
   account key, including legacy/plain fallback stores and OS-backed keychains.

Any change that can violate these invariants is a blocking correctness bug and
must be fixed before merge.

## Never Uninstall Device Apps Rule

Do **not** uninstall, delete, or wipe the Sonar app on personal/physical test
devices (`adb uninstall`, `pm uninstall`, Xcode "Delete App", erase-install,
or any equivalent) to work around install failures, storage pressure, signing
mismatches, or stale builds.

Uninstalling clears the on-device Marmot/`nsec` account key, wallet restore
material, and encrypted chat database — the same class of damage forbidden by
the Account Key Durability Rule. Users have lost account keys this way.

When installing or updating a Debug/Release build on a connected device:

1. Prefer in-place replace only: `./gradlew :composeApp:installDebug`,
   `adb install -r`, or an Xcode/devicectl install over the existing app.
2. If install fails (`INSTALL_FAILED_INSUFFICIENT_STORAGE`, signature mismatch,
   version downgrade, etc.), **stop and report** the error. Ask the user how to
   proceed. Do not uninstall to make the install succeed.
3. Freeing storage or fixing signing must not remove the Sonar package/app. If
   space is needed, ask the user to free it; never delete Sonar for them.
4. Emulators, CI harnesses, and explicitly disposable benchmark profiles are
   exempt only when the user (or the bench script contract) clearly marks that
   target as wipe-ok — never assume a named personal device is wipe-ok.

## Push Notifications Build Requirement (Firebase / GoogleService-Info.plist)

Offline wallet/payment wakeups (the Breez NDS push path) require the Firebase
config file `ios/bitchat/GoogleService-Info.plist`. It is **gitignored** and
**auto-bundled** by the Xcode 16 synchronized folder group (no pbxproj entry):
if the file is physically present in `ios/bitchat/` it ships in `Sonar.app`; if
it is missing, `FirebaseApp.configure()` is skipped (it is guarded on the file
in `BitchatApp.swift`), no FCM token is minted, the Breez webhook is never
registered, and **the build launches fine but silently has no offline payment
notifications** — only a warning is logged. Before any TestFlight/App Store
archive or device test, verify `ios/bitchat/GoogleService-Info.plist` exists
(copy it from another worktree / CI secret if creating a fresh checkout); never
commit it. This affects ONLY the Breez/payment path — Marmot chat/call wakeups
go over the Transponder raw-APNs path and do not depend on Firebase.

## Release URL Build Setting Check

Before any TestFlight/App Store archive, verify release-resolved URL build
settings are not malformed. In `.xcconfig` files, `//` starts a comment, so a
value like `NDS_URL = https://nds.sonar.hedwig.sh` resolves to the broken
sentinel `https:`. `NDS_URL` should normally come from the committed Release
default as the bare host `nds.sonar.hedwig.sh`; do not override it in
`Local.xcconfig` unless you are pointing at a private push stack. Check the
resolved Release setting without printing secrets:

```sh
xcodebuild -project ios/bitchat.xcodeproj \
  -scheme 'bitchat (iOS)' \
  -configuration Release \
  -showBuildSettings \
  | awk '/^[[:space:]]+NDS_URL = /{print}'
```

The value must never be empty, `https:`, `http:`, or anything without a host.
If this check fails, fix the build setting before archiving; otherwise the app
can launch successfully while silently disabling Breez offline payment wakeups.

## Regression Invariant Rule

Some bugs in this repo have been fixed more than once. [`docs/REGRESSIONS.md`](docs/REGRESSIONS.md)
records their invariants, the test that pins each one, both platforms' call
sites, and the approaches already tried and reverted.

Read it **before** changing conversation, transcript, send/echo, dedup, or
notification behaviour — and especially before editing the mirror pair
`apps/sonar/.../SonarAppState.kt` and `ios/bitchat/Views/Sonar/SonarAppStore.swift`,
or `ios/bitchat/Views/MarmotChatView.swift` and `core/sonar-core/src/client.rs`.
These four attract the most fix commits in the repo (the ledger documents the
command to re-derive the ranking), and the first two are the same conversation
logic written twice. If a change there looks like an obvious simplification,
check the `Rejected` notes first: it has often already been tried and reverted.

When fixing a bug that has now happened twice, add an entry. Rules:

1. Every entry names a `Guarded by:` test that **fails without the fix**. No test, no entry — put it under `## Unguarded` instead, which is the backlog.
2. Prefer a test that pins the **real call site** over one that pins a helper it feeds itself. R-001 regressed through a missing argument at a call site while every helper-level test stayed green.
3. Every entry carries **both** platform call sites (`ios/` and `apps/sonar/`), or states why one does not apply. A fix landing on one platform and not its mirror is the most common way these bugs return — see the Cross-Platform Feature Rule.
4. Record what you rejected and why, not just what you shipped.
5. State what is **not** guarded. An entry that overclaims coverage is worse than an admitted hole.

`scripts/check-regression-ledger.sh` runs in CI and fails if a citation does not
resolve to a real, enabled test (declared in a test source set, annotated, not
`@Ignore`d). It cannot tell whether a test is meaningful, whether it pins the
real call site, or whether it runs in CI at all — iOS tests currently do not.
Those stay review questions.

## Fix What We Break Rule

When a change breaks existing behavior, fix the broken behavior directly before considering the work complete. Do not leave regressions for users to route around, and do not hide them with UI-only workarounds.

For conversation identity specifically, a person must never be split into separate chats just because discovery arrives over different transports or in a different order. If a peer is first seen as Bitchat/mesh and later advertises Sonar features, fold the Bitchat, Sonar Discovery, and White Noise/Marmot legs into one conversation using the stable Noise fingerprint and NIP/npub identity link.

## Android Build & Run

Full guide: [`docs/ANDROID-BUILD.md`](docs/ANDROID-BUILD.md). App overview:
[`apps/sonar/README.md`](apps/sonar/README.md).

Compose app root: `apps/sonar/`. Gradle runs `core/build-android.sh` via
`:composeApp:buildAndroidRustCore` (JNI `.so` + UniFFI under
`composeApp/src/androidMain/`).

```bash
cd apps/sonar

# Day-to-day: install debug on a connected arm64 device/emulator
./gradlew :composeApp:installDebug

# Release APK — phones only (arm64-v8a + armeabi-v7a), default for GitHub alpha
./gradlew :composeApp:assembleRelease
# → composeApp/build/outputs/apk/release/composeApp-release-unsigned.apk

# Universal fat APK — also ships x86/x86_64 emulator natives
./gradlew :composeApp:assembleRelease -Psonar.universalApk=true
```

Secrets (gitignored; never commit):

- `apps/sonar/local.properties` — `sdk.dir=…` and `breez.apiKey=…` (or env
  `BREEZ_API_KEY`). Without the key the app builds; wallet/payments will not.
- `apps/sonar/composeApp/google-services.json` — FCM for offline payment wakeups;
  missing file ⇒ silent no FCM (same class of issue as iOS
  `GoogleService-Info.plist`).

Debug is **arm64-v8a only**. Default release is **phones only**; universal is
opt-in via `-Psonar.universalApk=true`. Website download points at the phone
APK; GitHub pre-releases may attach both phone and universal assets.

Force a native rebuild after `core/` changes if needed:

```bash
ANDROID_NDK_HOME=/path/to/ndk core/build-android.sh
```

## Zapstore Publish (Android)

Full guide: [`docs/ZAPSTORE.md`](docs/ZAPSTORE.md). Config: root
[`zapstore.yaml`](zapstore.yaml). Helper: `scripts/zapstore-publish.sh`.

Zapstore needs a **v2+ signed** phone APK (unsigned `assembleRelease` fails on
targetSdk 35) and Nostr signing via env `SIGN_WITH` (`nsec1…`, `bunker://…`, or
`browser`). Alpha GitHub releases are pre-releases — always use
`zsp publish --pre-release` (the script does).

Keystore secrets (gitignored `apps/sonar/local.properties` or env):
`sonar.keystore`, `sonar.keystore.password`, `sonar.key.alias`,
`sonar.key.password` (or `SONAR_KEYSTORE*` / `SONAR_KEY_*`). Put the publisher
`pubkey` (npub) in `zapstore.yaml` and commit it so the relay can whitelist the
repo.

```bash
export SIGN_WITH=browser   # or nsec / bunker
export GITHUB_TOKEN="$(gh auth token)"
scripts/zapstore-publish.sh --local   # build + sign + publish
# scripts/zapstore-publish.sh --check  # fetch-only dry run
```

## Blog Posting Process

The website blog (`web/src/routes/blog/`) renders NIP-23 (kind 30023) long-form
posts published to Nostr by the blog author key (`BLOG_PUBKEY_HEX` in
`web/src/lib/blog-data.js`). Posts are authored as Markdown under
`docs/blog/<slug>/README.md` with YAML front-matter (`title`, `cat`, `date`,
`summary`, `author`, `read`, `feature`). Every post MUST carry the
`sonarblogpost` marker `t` tag — the site loads only events with it, so other
long-form content from the same key never appears — which
`scripts/blog/publish.sh` adds automatically.

English NIP-23 is the source of truth. Site-only locale overlays
(`it` / `de` / `es` / `pt` / `fr`) live in `web/src/lib/blog-translations.js`
and are merged client-side after bake / live fetch. Overlays are keyed by a
`contentHash` of the English title/excerpt/md — if the English post changes and
overlays are not refreshed, non-English readers fall back to English rather
than showing a stale translation.

**Every time you post or update a blog post, run all of these steps** (they are
the operation that makes a post actually show up on the site):

1. Write/edit `docs/blog/<slug>/README.md` (front-matter + Markdown body).
2. Publish to Nostr — adds the marker tag; NIP-23 is addressable, so
   re-publishing the same slug **replaces** the existing event, it does not
   duplicate it:
   ```sh
   SONAR_BLOG_NSEC='nsec1…' scripts/blog/publish.sh <slug>   # --dry-run to preview
   ```
   Or configure the signer once in gitignored `scripts/blog/.env`
   (`SONAR_BLOG_NSEC` or `SONAR_BLOG_BUNKER`; see `scripts/blog/.env.example`).
   nak is invoked via `go run`, so no binary install is needed.
3. Bake the published posts + author profile (and refresh locale overlays when
   the translate secret is available):
   ```sh
   cd web && npm run fetch-blog
   # regenerates web/src/lib/blog-content.js
   # and, if SONAR_BLOG_TRANSLATE_API_KEY is set, updates
   # web/src/lib/blog-translations.js via translate-blog
   ```
   `fetch-blog` is Node-only (global WebSocket, no nak/Go) and best-effort: if
   the relays are unreachable or no marked post is found, it leaves
   `blog-content.js` untouched and exits 0. Without the translate secret,
   committed overlays are left as-is (they will not match a changed English
   post until you re-run with the key or hand-update them).
4. Commit the regenerated bake files together with
   `docs/blog/<slug>/README.md`:
   - `web/src/lib/blog-content.js` (always, when bake succeeded)
   - `web/src/lib/blog-translations.js` (when overlays changed)
   **Never commit `scripts/blog/.env`** (signer secret) or put
   `SONAR_BLOG_TRANSLATE_API_KEY` in client code — keep it in the local env /
   CI secret for main deploy only (not PR builds).

You do not strictly need to run step 3 by hand for production: the Pages CI
build runs `npm run fetch-blog` before `npm run build` on every deploy to
`main`, so the live site re-bakes English posts (and overlays when the
translate secret is configured on that job). Committing `blog-content.js` and
`blog-translations.js` keeps a fresh local/offline fallback and makes
`/blog/#<slug>` work in `npm run dev` and as the CI fallback when relays are
down. The page also refreshes from the live feed at runtime; overlays are
re-applied by post id. Relay-sourced Markdown is rendered through the shared
sanitizing renderer (`web/src/lib/markdown.js`); keep its HTML-escaping and href
scheme allow-list intact when touching that file.
