# MSN-style Trill (nudge) for every chat

Date: 2026-07-18 · Branch: `claude/chat-trill-notifications-a1251a`

## Clarified Problem Statement

**Goal:** Let a user send an MSN-Messenger-style "trill" (nudge) in any chat — mesh
or Marmot, DM or group — that shakes the recipient's transcript, plays a bell, fires a
haptic, and leaves a persisted system row in the history on both iOS and Android.

**Constraints**

- Cross-Platform Feature Rule: core + Android + iOS in the same change (user-confirmed,
  overrides the standing "no iOS/macOS for now" preference for this feature).
- Signal-Comparable Performance Rule: sending a trill must not block on relay connect;
  it goes through the same local-echo + background-publish path as a normal send.
- Chat-type rule (`docs/CHAT-TYPES.md`): must work for BOTH pure Marmot chats and
  mesh-folded chats. These have different id models — the reactions feature needed a
  separate mesh codec + Marmot kind for exactly this reason.
- Design fidelity (`design-handoffs-reproduce-not-reskin`): reproduce the Claude Design
  prototype 1:1, do not invent UI. The design ships a `nudge` icon (bell + motion arcs).
- Abuse guards required: sender cooldown **and** receiver throttle **and** per-chat mute.
  Note: **per-chat mute does not exist in Sonar today** — see "Silence semantics" below.
  It is a new vertical slice, not a toggle on existing infrastructure.
- Notification intensity: in-app full (shake + haptic + bell); background/killed gets a
  normal notification with a distinct trill sound. **No** critical-alert / DND bypass.

**Non-goals**

- No DND / silent-mode bypass, no iOS critical-alert entitlement.
- No custom trill sounds, no trill-back-at-sender, no trill in geohash/public channels.
- Not syncing the whole design bundle's unrelated new screens (Stickers, Fight Chat
  Control) as part of this feature — separate vendoring commit.

**Success criteria**

- A trill sent from Android arrives on iOS (and vice versa) in a Marmot chat and in a
  mesh-folded chat, rendering as a centered system row on both.
- Receiving with the chat open: transcript shakes, haptic fires, bell plays.
- Receiving backgrounded: one notification with the trill sound. Receiving killed:
  same, via the existing push wakeup path.
- Spamming the button sends at most one trill per cooldown window; a peer that ignores
  the cooldown gets collapsed receiver-side.
- Muting a chat suppresses sound/haptic/shake but still writes the row.
- A trill from a blocked peer produces nothing at all — no row, no alert.
- Guarded by a core round-trip test + a codec test per platform + a mute-suppression test.

---

## Design spec (verified against the Claude Design project, 2026-07-18)

Read from `sonar/app.jsx` in project `c6936a45-1fde-470e-9d0b-56b04428e60b`. The design
calls it **nudge** — use that name in code; "trill"/"trillo" is the user-facing Italian
term. The local vendored bundle is STALE and does not contain any of this.

**`buzz()` — the receive/send effect, all three channels fired together:**

- **Shake:** `data-shake="1"` set on the app root, removed after **620ms**.
- **Bell:** two identical tones **160ms apart** (`[0, 0.16]`). Each is a sine oscillator
  from **880Hz ramping exponentially to 660Hz over 120ms**; gain envelope
  0.0001 → 0.32 (attack 20ms) → 0.0001 (decay to 220ms); each tone stops at 240ms.
  Total bell ≈ 400ms. Reproduce as a bundled asset, not a synthesized tone, on device.
- **Haptic:** `navigator.vibrate([40, 60, 40])` — buzz 40ms, pause 60ms, buzz 40ms.
  Maps to `VibrationEffect.createWaveform` on Android and a two-pulse
  `UIImpactFeedbackGenerator(.medium)` sequence on iOS (cf. the existing `🫂 hugs`
  precedent at `ChatViewModel.swift:3920`).

**Scope, as wired in the design:**

- `sendNudge(peerId)` → `DMScreen onNudge` — DMs **in scope**.
- `sendNudgeGroup(groupId)` → `GroupScreen onNudge`, row carries `author` — groups
  **in scope** (resolves the earlier open question).
- `ChannelScreen` has **no** `onNudge` — public channels **out of scope**. Confirms the
  stated non-goal.

**Transcript row:** `{ nudge: true, mine, time }` (plus `author` for groups) — a row
sibling to `pay`/`call`/`action`, i.e. a distinct non-text row type, exactly matching
the "persisted system row" decision.

**Mute is already designed** (this was the biggest gap in the earlier draft):

- State `muted: {}`; `muteConv(id, dur)` defaulting to `'forever'` — so **durations are
  specified**, matching Signal's model.
- `unmuteConv(id)`.
- Surfaced in three places: `HomeScreen` (`onMute`/`onUnmute`), `DMScreen`
  (`onMute`/`onUnmute`), and `SettingsScreen` (`onUnmute` — a managed list of muted
  conversations).

This settles the mute-sequencing decision: mute is not scope creep invented to guard the
trill, it is part of the same design. **Fold it in.**

Note the design does not model the *receiving* side of mute (a static prototype has no
real peers — `buzz()` fires unconditionally on send, which is only the sender's own
echo). The mute-suppresses-trill rule below therefore remains our design decision, not
something read off the prototype.

## Silence semantics

**Finding: Sonar has no mute.** Zero hits for `isMuted` / `muteChat` / `mutedUntil`
across `apps/sonar/` and `ios/`. The only existing suppression concept is **block**
(`ios/bitchat/Identity/SecureIdentityStateManager.swift:426`,
`SonarAppState.kt:1914 isBlockedPeer` / `:1917 isBlockedNostrPubkey`), which drops the
peer wholesale. So "mute trills per chat" is not a checkbox on existing state — per-chat
mute must be built.

"A silenced chat" resolves to three different things, which must behave differently:

| Silence level | Exists today? | Trill behaviour |
|---|---|---|
| Blocked peer | Yes | Nothing. Dropped at ingest — no row, no alert |
| Muted chat | **No — must be built** | **Row only.** No shake, bell, haptic, or notification |
| OS silent / DND | OS-level | Notification delivered silently; row still written |
| Not silenced, backgrounded | Yes | Notification + trill sound + row |
| Not silenced, chat open | Yes | Shake + haptic + bell + row |

**Invariant: a trill never produces less than a persisted row, and never more than the
chat's notification level already allows.**

**Mute wins over trill.** Rejected the alternative (trill punches through mute) despite
"break through inattention" being the feature's stated purpose:

- Mute is explicit per-chat user intent. A signal that overrides it is a harassment
  vector — bypassable nudge is exactly what made MSN's version notorious.
- If trill bypassed mute, mute becomes useless and users reach for **block** instead.
  That is strictly worse for the sender: block is invisible and permanent, mute is
  recoverable.
- The persisted row is what rescues this. Attention is *deferred*, not denied — the
  recipient opens the chat later and sees the trill. This is the main argument that the
  persisted-row decision (over ephemeral) was correct.

Two derived decisions:

1. **Build general per-chat mute, not trill-specific mute.** Per the Signal-First Design
   Rule, Signal ships per-conversation mute with durations (1h, 8h, 1d, 7d, always).
   Trill then merely *reads* that state. A trill-only mute is a seam that gets ripped out
   the first time someone wants to mute a noisy group.
2. **The receiver throttle throttles the alert, not the row.** Always write the row;
   alert at most once per window. Collapsing repeated trills into a single row with a
   count (reactions-style aggregation) is nicer but real work — deferred.

---

## Two blocking findings

**1. Reactions are NOT on this branch.** The natural scaffolding for a trill — the
long-press action sheet, the ephemeral-signal precedent, the `⚡REACT` mesh codec pair,
the ~10 suppression call sites for preview/recency/resync-floor — lives only on the
unmerged `origin/claude/strange-mendeleev-63c79f` (25 files, +2730/-551). On HEAD none
of it exists. Every approach below must state whether it depends on that branch landing.

**2. The local design bundle is stale — still un-vendored.** `design/handoff/` is at
2026-06-16 (+Docs 07-07, +Blog 07-14). Remote has the `nudge` icon and the full nudge
implementation in `sonar/app.jsx`, neither of which exists locally, plus
`Fight Chat Control.html`, `Sonar Stickers.html`, `sonar/stickers/*`.

The nudge spec above was read out of the remote project and recorded here, so
implementation is unblocked. But **the bundle itself has not been re-vendored yet.**
Do it via the tar route `SOURCE.md` already documents (fetch the share URL, extract,
`cp -R` over `design/handoff/`) — one shell command for the whole bundle. Do NOT do it
by round-tripping ~30 files through `DesignSync.get_file`: that is a read + rewrite per
file through an agent's context, which is slow and expensive. Note `DesignSync` is also
not reachable from subagents, so it cannot be delegated.

Still unread from the design (fetch if the implementation needs them): `sonar/
components.jsx` (the nudge row markup), `sonar/theme.css` (the shake keyframes and
`.nudge*` styles), `sonar/screens.jsx` (where the nudge button sits in the DM/group
header or composer).

---

## Approaches Considered

### Approach A: Trill as a marked message (the repo's existing idiom)
- **Sketch:** A trill is a real message whose content is a reserved control line
  `⚡TRILL|1|<nonce>`. It rides the normal send path on both legs — Marmot kind-9 and
  mesh private-message — with no new wire format, no new noise payload byte, no new
  UniFFI callback. Hosts detect the prefix at render time and swap the bubble for a
  centered system row.
- **Precedent on HEAD (verified):** this is the established repo idiom, used twice
  already *on this branch* — `⚡PAY|1|<id>|<sats>` / `⚡PAYDONE|1|2` (`notification.rs:46`,
  `SonarPay.kt:20`, `SonarPayLedger.swift:27`) and `☎CALL|1|OFFER|…`
  (`call/signaling.rs:15-28`, `CALL_PREFIX`). The branch's `⚡REACT` is a third instance
  but is **not** on HEAD, so it is precedent, not reusable code.
- **Concrete integration point:** `core/sonar-core/src/notification.rs:36
  classify_content()` already dispatches control lines →
  `NotificationKind::{Call, Payment, Message}`. A trill adds a `Trill` variant there and
  both hosts' notification routers pick up the distinct sound from it. This is a much
  smaller hook than the reactions feature needed.
- **Follow the versioned-parse discipline:** `CallControl::parse` rejects any version
  other than 1 (`signaling.rs:313` — `☎CALL|2|…` → `None`). `⚡TRILL` must parse the same
  way so a future v2 degrades to plain text on old clients rather than mis-rendering.
- **Affected files:** core `marmot.rs` (prefix const + preview/recency suppression),
  `notification.rs:36` (`NotificationKind::Trill`), `client.rs` `send_text` marker arm,
  `conversation_index.rs` preview skip; new codec pair `SonarTrill.swift` /
  `SonarTrill.kt` (mirroring `SonarPayLedger.swift` / `SonarPay.kt`);
  `SonarAppState.kt` + `SonarAppStore.swift` render + notify; `Notifier.kt` sound enum;
  `NotificationService.swift` sound.
- **Spec doc:** add `docs/SONAR-TRILL.md`, matching the existing `docs/SONAR-PAYMENTS.md`
  convention that control-line formats get a written spec.
- **Tradeoffs:** Persistence, offline delivery, push wakeup, dedup, echo reconcile and
  cross-leg folding all come free from the message pipeline — which is precisely what
  the user asked for with "persisted system row". Independent of the reactions branch.
  **Cost:** an old client that doesn't know the prefix renders a raw `⚡TRILL|1|…` text
  line. Same forward-compat wart reactions already accepted. Also inherits the ~10
  suppression call sites — miss one and a trill becomes a chat-list preview.
- **Effort:** M

### Approach B: First-class ephemeral signal (new kind + new noise payload byte)
- **Sketch:** New Marmot rumor kind and a new `noise_payload` type code (e.g. `0x04`)
  on the mesh leg. Core surfaces it through a new `#[uniffi::export(callback_interface)]
  trait TrillListener` with its own mpsc shim, since `ConversationChangeListener` carries
  only a group id and an ephemeral signal has no row to re-read.
- **Affected files:** `mesh.rs:595` + `BitchatProtocol.swift:103` + `NoisePayload.swift`
  (payload codes), `marmot.rs` (`Incoming::Trill`), `sonar-ffi/lib.rs:415` (new listener),
  both hosts' listener plumbing.
- **Tradeoffs:** Clean wire format, no raw-text leak on old clients, no suppression call
  sites to miss. **But** it contradicts the confirmed "persisted system row" decision —
  you'd have to add local persistence back by hand, plus a separate push path, since an
  ephemeral signal has no message row to wake on. Strictly more work for a shape the user
  did not pick.
- **Effort:** L

### Approach C: UI-only, ride the reactions branch
- **Sketch:** Wait for `claude/strange-mendeleev-63c79f` to merge, then add a trill as
  a special emoji reaction rendered as a system row.
- **Tradeoffs:** Smallest diff, but semantically wrong — a reaction targets a message,
  a trill targets a conversation, and the reaction pipeline deliberately skips the push
  wakeup a trill needs. Hard-blocked on an unmerged branch. Listed for completeness.
- **Effort:** S, but blocked and semantically wrong.

---

## Recommendation

**Approach A.** It matches the confirmed "persisted system row" decision, it is the
idiom the repo already ships twice on HEAD (`⚡PAY`, `☎CALL`), and it is the only option
independent of the unmerged reactions branch. `classify_content()` gives it a ready-made
notification hook. The forward-compat wart (old clients see raw text) is real but already
precedented, and is bounded by the versioned-parse discipline; it can be narrowed later
by moving to Approach B's payload byte without changing the UI layer.

Sequence it as: (0) sync the design bundle and read the nudge design → (1) core prefix +
suppression + test → (2) codec pair + platform tests → (3) per-chat mute vertical slice →
(4) Android UI/haptics/sound → (5) iOS UI/haptics/sound → (6) guards (cooldown, throttle).

Effort revised **M → L** once per-chat mute is included.

## Open decision: mute sequencing

Per-chat mute is its own vertical slice across core + both apps. Either:

- **(a) Fold mute into this PR.** Recommended. Shipping a trill with no way to silence
  it is precisely the failure mode the abuse guards exist to prevent. Larger PR.
- **(b) Land trill first with `isMuted` hardcoded false**, mute as the immediate
  follow-up. Smaller reviewable steps, but leaves a window where the feature is
  unsilenceable — and per the Regression Invariant Rule, "follow-up" slices that gate
  safety have a poor track record of landing promptly.

**Not yet decided by the user.** Resolve before planning.

## Open questions

- Does the remote design actually specify trill UI (send affordance, system-row copy,
  shake animation), or only ship the icon? Resolve by syncing the bundle first — this
  gates step 0 and could change the UI plan.
- Group chats: does a trill notify every member, or is it DM-only for v1? Leaning
  DM + small groups, with the same per-chat mute applying.
- Android has **no haptics anywhere** in the Compose app today (only
  `Notifier.android.kt` touches vibration). The trill introduces the first in-app haptic
  — worth a tiny shared abstraction rather than a one-off call.
- Should the mesh leg trill at all when the peer is out of BLE range, or fall back to
  the Marmot leg? Follow whatever `sendDmAuto` already decides.
- Does per-chat mute need to sync across a user's linked devices (PR #195 second MLS
  leaf), or is it local-only per install? Local-only is far cheaper; Signal syncs it.
  Leaning local-only for v1 with a documented gap.
- Should a muted chat still show an unread badge for a trill, or is the row silent
  until opened? Leaning badge — the row exists, so the chat is genuinely unread.
