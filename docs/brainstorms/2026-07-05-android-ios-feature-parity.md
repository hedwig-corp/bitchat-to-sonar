# Android ↔ iOS Feature Parity — Audit + Execute

Date: 2026-07-05

## Clarified Problem Statement

**Goal:** Bring the Compose Multiplatform app (`apps/sonar/`) to full user-facing
feature parity with the native iOS app (`ios/bitchat/`), by first producing an
authoritative gap matrix (including iOS work landed since the 2026-06-27
delivery plan) and then closing every gap across messaging/delivery,
payments/wallet, calls, and media/UX — each device-verified before it counts.

**Chosen approach:** Approach B — parallel-audit + parallel-implement.
Fan out read-only audit agents (one per iOS surface) to build the matrix fast,
synthesize, then implement independent gaps in parallel worktrees where safe.
Ship each gap as a small independently-reviewable PR with A's slice discipline.
Device-verify in batched sessions per surface.

**Constraints:**
- Cross-Platform Feature Rule + Fix-What-We-Break Rule: parity items ship for
  the surface that lacks them; regressions fixed directly.
- Signal-Comparable Performance Rule: no parity change may move sync/relay work
  onto the chat-open/send/scroll critical path; no side effects on the Compose
  render path.
- CI only runs `cargo test --workspace`; apps can't build in CI (gitignored FFI
  + secrets). Android oracle: `cd apps/sonar && ./gradlew :composeApp:assembleDebug`
  + `testDebugUnitTest`. Preserve gitignored secrets (`apps/sonar/local.properties`,
  `ios/Configs/Local.xcconfig`, `ios/bitchat/GoogleService-Info.plist`).
- Device-verified = real Android device, plus iOS interop where the feature
  crosses platforms (needs ≥2 BLE phones for mesh legs). Hardware-gated items
  get a manual test checklist and are batch-verified at surface boundaries.
- Wire-compat: shared behavior belongs in `core/sonar-core`; iOS stays Swift
  where wire-compat suffices.

**Non-goals:**
- No net-new features that don't exist on iOS (parity, not roadmap).
- Not re-doing slices 1–4 of `docs/ANDROID-IOS-PARITY-DELIVERY-PLAN.md`
  (shipped in PR #140) — only verify + patch drift.
- Zaps (#24), video-call media transport (iroh-roq blocker), BIP-39 wallet-seed
  convergence — remain tracked gaps unless the audit reveals a cheaper path.

**Success criteria:**
- A living parity matrix (`docs/ANDROID-IOS-PARITY-MATRIX.md`) enumerating
  every iOS surface × Compose status (parity / gap / platform-gap-with-reason).
- Every "gap" row closed by a small independently-shippable PR, unit-tested,
  cargo/gradle green.
- Each shipped item has a completed device-test checklist entry.
- Slice 5 leftovers (call video button, contact-profile favorite/block actions,
  start-chat tap→DM, reaction/location placeholders, delivery-status copy)
  resolved or explicitly marked platform-gap.

## Audit inputs
- iOS work landed since 2026-06-27 that Android may not mirror: offline payment
  notifications (#153, #155, #147), Marmot resync cursor (#160), direct-chat
  dedupe (#164), nonblocking secure chat startup (#159), mesh BLE reconnect
  alert silencing (#163), BLE discovery power policy (#145), core-rendered
  notifications (#144), bolt12 offer preservation (#138), account key
  persistence hardening (#158).
- Unmerged parity branches to triage before net-new work:
  `codex/android-ios-parity-slash-commands`, `codex/android-offline-push-parity`,
  `codex/android-parity-delivery`, `codex/media-interactions-parity`,
  `claude/android-relay-thrash-parity`.
- Priority order: messaging & delivery → payments & wallet → calls → media/UX.

## Open questions (non-blocking)
- Hardware inventory for interop legs (# Android phones, iPhone availability).
- Whether any codex/* branch content should be cherry-picked vs reimplemented.
