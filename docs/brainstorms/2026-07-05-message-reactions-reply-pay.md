# Message Reactions, Reply-to-Message, and Pay-to-Message (Bitcoin B)

Date: 2026-07-05
Status: Clarified — chosen approach: **B (core-owned, Nostr-native, aggregated in core)**, phased **reactions → reply → pay**.

## Clarified Problem Statement

**Goal:** Add Signal-style message reactions, reply-to-message (quote), and a per-message Bitcoin "zap" (long-press → **B** → amount → pays the message author, with a ⚡B badge on that message) — across both the Marmot/Nostr and BLE mesh transports, on iOS (`ios/`) and the Compose Multiplatform app (`apps/sonar/`). Ship in three separate changes: **reactions → reply → pay**.

**Constraints:**

- Cross-Platform rule: every change lands on both `ios/` and `apps/sonar/` together, or documents a tracked gap.
- Signal-first rule: study Signal's `MessageRecord` reactions + `QuotedAttachment`/reply model before building; document adopted vs deferred patterns in each PR.
- Signal-Comparable Performance: reactions/replies must paint from the local DB first; relay sync stays a background updater. No aggregation on the Compose render path — resolve in background loops.
- Reactions: Signal tapback semantics — fixed quick set (❤️👍👎😂😮😢) + "+" full picker, **one reaction per person per message, toggle to remove**, clustered counts under the bubble.
- Pay-to-message: reuses the existing wallet + `PayLine`/`⚡PAY` plumbing; settles immediately; ⚡B badge attaches to the specific message for both sides.
- Both transports in v1 — mesh messages need a stable referenceable ID and a control-frame format alongside the Nostr path.
- Account-key/secrets rules unaffected (no identity or secret surface touched).

**Non-goals:**

- Nostr public zaps / NIP-57 lightning zaps to the relay (this is an in-chat tip, not a public zap receipt).
- Reacting with custom animated reactions (emoji only for v1).
- Multi-emoji-per-person, super-reactions, or reaction animations.
- Editing/deleting the reacted-to or replied-to message.

**Success criteria:**

- Long-press any message on either platform → context menu with React / Reply / **B** (pay).
- A reaction sent on iOS appears clustered under the bubble on the Compose peer (and vice versa), over both Marmot and mesh, and toggles off when re-tapped.
- A reply renders a tappable quoted snippet above the new message; tapping scrolls to the original.
- Paying a message deducts from the wallet, the author receives sats, and a ⚡B<sats> badge attaches to that exact message on both sides.
- Cold chat-open time and scroll perf unchanged vs baseline (`scripts/bench/`).

## Codebase Map (from exploration)

| Component | iOS | Compose | Rust core |
|-----------|-----|---------|-----------|
| Message model | `ios/bitchat/Models/BitchatMessage.swift` | `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarCore.kt` (`SonarMsg`) | `core/sonar-core/src/marmot.rs` (`ChatMessage`, `CHAT_RUMOR_KIND = 9`) |
| Bubble UI | `ios/bitchat/Views/Components/SonarMessageBubbleView.swift` | `App.kt` `MessageBubble` (~line 1349) | — |
| Payment UI | `ios/bitchat/Views/Components/PaymentChipView.swift` | `SonarPayViews.kt` (`PaySheet`, `PayBubble`) | — |
| Payment protocol | `MessageTextHelpers.swift` | `SonarPay.kt` (`PayLine`, `⚡PAY\|1\|<uuid>\|<sats>`) | `core/sonar-core/src/notification.rs` (classify only) |
| FFI surface | — | — | `core/sonar-ffi/src/lib.rs` (`MessageInfo.id_hex`, `send_text` @651, `messages*` @817–917) |
| Send path | — | — | `SonarClient::send_text` (client.rs:1522) → `MarmotEngine::create_text_message` (marmot.rs:445) → MDK `create_message` → outbox publish |

Key facts:

- Stable message ID = Nostr `EventId` (64-hex `id_hex` over FFI). This is the reference key for reactions/replies/tips on the Marmot path.
- No existing NIP-10 (`e`/`q` tags), NIP-25 (kind-7), or reply/reaction fields anywhere. MDK already stores non-kind-9 rumors beside chat messages and the transcript filter (`marmot.rs:708`) drops them — so kind-7 reactions can flow through the existing pipe and just need aggregation.
- Breez is app-layer only; core only classifies `⚡PAY` control lines.
- BLE mesh: separate `sonar-ble` crate, Noise-encrypted frames, non-Nostr. Mesh reactions need a control frame keyed by a stable mesh message ID (**verify stability of that ID in Phase 1**).

## Chosen Approach B — core-owned, Nostr-native, aggregated in core

1. **Reactions (change 1, sets up shared plumbing)**
   - Core: encode a reaction as an inner rumor of **kind 7 (NIP-25)** with an `e` tag → target `EventId`, `content` = emoji (or `+`/`-` normalization on read). Sent through the same MDK/outbox pipe as kind-9.
   - Core aggregation: when building transcript pages, aggregate kind-7 rumors per target message → expose `reactions: Vec<ReactionInfo> { emoji, count, mine, senders }` on `MessageInfo`. Toggle-off = new kind-7 with a deletion/negation semantic (use content `-` + `e` tag per NIP-25) — last-write-wins per (sender, target).
   - FFI: `send_reaction(group_id_hex, target_message_id_hex, emoji)` and reaction data on `MessageInfo`; regenerate UniFFI bindings + `sonarffi.xcframework` + JNA host dylib.
   - Mesh: `REACT` control frame in `sonar-ble` carrying (target message id, emoji, toggle).
   - Apps: long-press context menu (`.contextMenu`/quick tapback bar on iOS; `combinedClickable` long-press sheet in Compose), reaction cluster row under bubbles. UI renders exactly what core hands it; DB invalidation drives updates.
2. **Reply (change 2)**
   - Core: kind-9 rumor with NIP-10 `e` tag (marker `reply`) → `reply_to: Option<ReplyInfo { id_hex, snippet, sender }>` on `MessageInfo`; `send_reply(group_id_hex, reply_to_id_hex, text)` FFI.
   - Apps: quoted snippet above bubble, tap-to-scroll; reply action in the shared context menu. Mesh: `REPLY` frame or inline quote encoding.
3. **Pay-to-message (change 3)**
   - Long-press → **B** action → existing `PaySheet` pre-targeted to message author; on settle, send a `⚡PAYMSG|1|<payment_id>|<sats>|<target_message_id>` control line (extend `PayLine`), core classifies + attaches as a `tip` aggregate on the target `MessageInfo`; ⚡B badge row (separate from emoji reactions) on both platforms.

## Rejected Approaches

- **A — app-layer control lines only** (`⚡REACT|…` in message content): fastest, no core change, but duplicates aggregation in two app layers, makes every reaction a full message, leaks control lines into transcript/search, and bypasses the core-owned local DB design.
- **C — core encode/decode, app aggregation**: smaller core delta but re-duplicates aggregation and pushes it toward the Compose render path (performance-rule friction).

## Open questions (non-blocking)

- ⚡B tip badge: separate row under the bubble (lean) vs a reaction slot.
- Reaction delivery: use existing outbox retry (lean) vs fire-and-forget.
- Reply across transport switch (mesh original → Marmot reply): quote survival ties into the one-conversation-per-person fold.
- Mesh stable-ID guarantee: confirm both ends see the same message ID for mesh DMs before keying mesh reactions off it (Phase 1 verification task).
