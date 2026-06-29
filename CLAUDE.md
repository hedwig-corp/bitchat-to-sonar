# Repository Guidance

## Cross-Platform Feature Rule

Sonar is a multi-platform product. New user-facing features must be designed and implemented for every supported app surface unless a platform limitation is documented in the change itself.

When adding or changing a feature, cover the native Apple app (`ios/`) and the Compose Multiplatform app (`apps/sonar/`) together. If a capability cannot ship on one platform in the same change, leave an explicit tracked gap with the platform, reason, and follow-up path.

## Signal-Comparable Performance Rule

Conversation and transcript changes must preserve Signal-comparable local-first performance. Opening an existing chat must paint from local storage first and must not wait on relay/server sync, full-history scans, or unrelated groups before first paint. If a change can make chat opening, sending, or scrolling meaningfully slower than Signal-style local database windowing, design a bounded local page/window path, move sync to the background, and document any platform gap with a follow-up path.

## Signal-Style Conversation Design Notes

Signal treats the local database as the chat state. Network receive/send/sync paths write into local storage first, then the chat list and transcript UI react to local database invalidation. Android pages local conversation rows from `ThreadTable` through `ConversationListDataSource` with a small paging window; iOS builds chat-list render state from local thread IDs through `CLVLoader` and caches row view models/content. Sonar conversation work should follow that model: maintain core-owned local conversation summaries ordered by latest message, hydrate visible chat rows from bounded local pages, open transcripts from bounded local message windows, and run relay sync only as a background database updater.

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

How to run the analysis:

1. Build the dependencies once: `core/build-ios.sh` (Rust core → `sonarffi.xcframework`, incl. the simulator slice), `cargo build -p sonar-cli --release` (headless counterparty), then `APP=$(scripts/bench/build-sim.sh)` (Debug, arm64, unsigned `.app`).
2. Faithful "existing account, cold process" run: `scripts/bench/provision-and-bench.sh --app "$APP" --runs 5 --msgs-per-run 3`. It seeds a real Marmot group via `sonar-cli` and pushes fresh messages before each run so every cold start exercises the real relay re-sync path (`woke=1`). For just the identity-independent phase breakdown, use `scripts/bench/cold-start-bench.sh --app "$APP" --runs 5`. To measure the REAL account on a physical iPhone (signed Debug build over the existing app, data preserved), use `scripts/bench/device-bench.sh` — this is where real pain points show up (e.g. the ~57 s blocking KeyPackage/profile publish on the cold-start critical path).
3. Read the per-phase min/median/max table. The app emits `SONAR_BENCH` markers (`t0_launch` → `t1_local_paint` → `t2_relay_connect_begin` → `t3_relay_connected` → `t4_first_drain`) via `SecureLogger.info` (subsystem `chat.bitchat`, category `session`, DEBUG-only `%{public}@`); the harness parses them from the unified log.

Constraints and gotchas (all detailed in `docs/PERFORMANCE.md`): the build must be **Debug** (markers are private in Release) and **arm64-only** (Arti/sonarffi sim slices are arm64). CLI sim builds are unsigned and cannot get a Keychain entitlement for the `sh.hedwig.sonar` bundle id, so the benchmark path is **Keychain-independent** — adopt the `SONAR_BENCH_NSEC` identity and derive the DB key from it. All such hooks are `#if DEBUG` and gated on `SONAR_BENCH_NSEC`; never add a benchmark hook that changes behavior in Release. When reporting, quote `launch→t4` (cold → synced) and the `t3→t4` sync drain against the baseline, and treat any regression that moves sync onto the critical path as a violation of the Signal-Comparable Performance Rule.

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

## Fix What We Break Rule

When a change breaks existing behavior, fix the broken behavior directly before considering the work complete. Do not leave regressions for users to route around, and do not hide them with UI-only workarounds.

For conversation identity specifically, a person must never be split into separate chats just because discovery arrives over different transports or in a different order. If a peer is first seen as Bitchat/mesh and later advertises Sonar features, fold the Bitchat, Sonar Discovery, and White Noise/Marmot legs into one conversation using the stable Noise fingerprint and NIP/npub identity link.
