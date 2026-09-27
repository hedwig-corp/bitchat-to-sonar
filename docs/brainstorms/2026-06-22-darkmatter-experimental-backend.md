# Darkmatter (Marmot v2) Experimental Backend — Brainstorm

Date: 2026-06-22
Tracking issue: https://github.com/hedwig-corp/bitchat-to-sonar/issues/59
Implementation plan: docs/plans/2026-06-22-darkmatter-experimental-backend.md

## Clarified Problem Statement

**Goal:** Land an experimental, feature-gated Darkmatter (Marmot v2) messaging path as a vertical
slice — new `sonar-core` module → `sonar-ffi` surface → hidden developer toggle in both the iOS and
Compose apps — without disturbing the production MDK path.

**Constraints:**
- Sibling, not replacement: `MarmotEngine` (MDK) in `core/sonar-core/src/marmot.rs` stays untouched;
  new code behind a default-off `darkmatter` cargo feature.
- Separate storage: Darkmatter state in its own SQLCipher DB; never read the MDK db with the v2 path.
- Pinned to a specific `darkmatter` rev (pre-release; default branch is `master`, repo self-describes
  as "An exploration").
- Both platforms behind a hidden dev toggle.
- Local-first / no side effects on the Compose render path.

**Non-goals (this slice):** MDK↔Darkmatter interop or in-place migration; auto-selecting v2 for real
peers (capability negotiation wired but gated); folding a v2 chat into the same conversation as an MDK
chat for the same person (deferred); media; group images; multi-device; production exposure.

**Success criteria:** `core` builds with `--features darkmatter` for iOS/Android/desktop (single
libsqlite3-sys build); behind the dev toggle a build creates a v2 group, sends + receives a text
message over Sonar's relays with the Sonar identity; production MDK chats unaffected with the feature
off.

## Capability signal decision: `sonar_protocol: u8`

Chosen over a boolean `supports_darkmatter`. Value = Marmot protocol version (1 = MDK, 2 = Darkmatter),
"implies support for 1..=N", absent ⇒ 1. New-chat engine = `min(my_sonar_protocol, peer_sonar_protocol)`.
Lives in the Sonar descriptor (`sonar_descriptor.rs`), so it governs Sonar↔Sonar; WhiteNoise/other
clients are detected from their published key-package event kinds (30443). Holds as long as Sonar keeps
the MDK engine during the migration window (issue #59 item #1); widen to a `[min,max]` range only if a
future Sonar drops v1.

## Approaches Considered

### Approach A — Thin "hello v2" slice via cgka-session + transport adapters (RECOMMENDED)
Bind the new `DarkmatterEngine` at the `cgka-session` + `transport-nostr-adapter`/`transport-nostr-peeler`
layer, reusing Sonar's identity/relays and a separate store. Keeps Sonar's ownership of identity/relays/
storage intact. Effort: M Rust + M ×2 apps.

### Approach B — App-runtime passthrough via marmot-account / marmot-app (+ marmot-uniffi)
Faster to feature-complete v2, but the runtime wants to own identity/storage/relays, fighting Sonar's
local-first conversation index; risk of a parallel runtime + double-SQLCipher. Rejected for now.

### Approach C — Capability-gated dual-stack from day one
Closest to issue #59's end state and honors "don't split a person" immediately, but much larger and
depends on upstream stability we don't have. Deferred; its routing/identity-fold work is staged into
Phase 3.

## Recommendation

Approach A, binding at `cgka-session` + transport-adapter layer. Honest first step for experimental
mode: proves the crates cross-compile alongside MDK and that a v2 message round-trips on our relays with
our identity, while keeping Sonar's ownership so B/C don't require a rewrite.

## Open questions

- Exact `darkmatter` rev to pin (master moves; WhiteNoise path-deps `../darkmatter`, no tag).
- `cgka-session` vs `marmot-account` binding layer (confirm once API is read).
- SQLCipher double-link with `mdk-sqlite-storage` — needs an early link check.
- FFI: distinct experimental group-id newtype (don't reuse `mdk_core::GroupId`).
- v2 account-identity-proof on key packages satisfied by Sonar's `Identity`?
- Conversation-split caveat: allowed only behind the dev toggle; resolve before user-facing release.
