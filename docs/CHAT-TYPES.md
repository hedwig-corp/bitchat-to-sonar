# Chat Types: Mesh-Folded vs Pure Marmot Conversations

Sonar renders every person as **one** conversation, but under the hood there are
**two structurally different kinds of chat**, and most conversation-layer bugs in
this repo come from code that silently assumes one kind while handling the other.
This document explains why both exist, how they differ, and the invariants any
feature touching conversations must respect.

The motivating incident (2026-07-16, PR #303): the Signal-style "open at first
unread" divider worked for some chats and not others. It split **by chat type,
not randomly** — pure White Noise/Marmot chats (header: *"End-to-end encrypted —
only you and X can read this"*) got the divider; mesh/radar chats (header:
*"Nearby · Bluetooth"* or *"Out of Bluetooth range — encrypted over the internet
instead"*) got nothing. Both root causes below are archetypes of this bug class.

## Why two kinds exist

Sonar merges two heritages with different network models:

- **bitchat BLE mesh**: peers discovered over Bluetooth, Noise-encrypted DMs,
  no servers. A peer is identified by key-derived ids (a 16-hex short id =
  `SHA256(noise static pubkey)[:8]`, and the full 64-hex Noise fingerprint).
  Messages live locally in `MessageStore`; there is no relay copy.
- **White Noise / Marmot**: MLS groups over Nostr relays. A conversation is an
  MLS **group** (id = 32-byte hex), members are **npubs**, messages are synced
  from relays into the core's encrypted SQLCipher DB, and the core maintains a
  `conversation_summary` index (latest row, message count, **unread count**).

A person met over Bluetooth who also has a White Noise account must be **one
chat** (see the Fix What We Break Rule in `CLAUDE.md`): if we first see them as
a mesh peer and later learn their npub (from the 0x53 announce), the Bluetooth
leg and the White Noise leg *fold* into a single thread. The reverse never
happens — a pure Marmot contact with no BLE discovery stays a plain Marmot chat.

That gives the two kinds:

| | **Pure Marmot chat** | **Mesh-folded chat** |
|---|---|---|
| Example | "Giulia.39" | "Sara D", "Vincenzo-Mac" |
| Chat id (`screen.id`) | MLS group id hex (`a36204925ec9…`) | `mesh:<canonical peer id>` (`mesh:f3237e63…`, 64-hex fingerprint or 16-hex short id) |
| Header banner | "End-to-end encrypted — only you and X can read this" | "Nearby · Bluetooth" / "Out of Bluetooth range — encrypted over the internet instead" / "Offline — will send later" |
| Message sources | 1..n direct Marmot groups (duplicates folded by peer key) | BLE `MessageStore` rows **plus** 0..n Marmot groups resolved via the peer's npub |
| Send transport | Always Marmot (relay) | Auto-picked per message: live Noise link ⇒ BLE; else Marmot; else NIP-17; else outbox (`sendDmAuto`) |
| Bubble colour | indigo (internet) | per-message: cyan = travelled over mesh, indigo = internet (`SonarMsg.viaInternet`) |
| Open path (Compose) | `SonarAppState.openChat` | `SonarAppState.openDm` |
| Open path (iOS) | `SonarAppStore.openedDM` (group resolved directly) | `SonarAppStore.openedDM` (group resolved via fingerprint/npub mapping) |

## The identity model (which id are you holding?)

Five different strings can identify "the same conversation". Confusing them is
the #1 source of mesh-only bugs:

1. **Mesh route id** — `"mesh:<peerId>"`. A UI/navigation key only. It is
   **never** a key in any core-owned map.
2. **Canonical mesh peer id** — 64-hex Noise fingerprint when known, else the
   16-hex short id. One peer accumulates *aliases* (rotating short ids, the
   fingerprint); `canonicalMeshPeerId` + `meshPeerAliases` normalize them.
3. **npub** — the peer's White Noise account. The bridge between legs:
   `npubRawFor(peerId)` → `marmotGroupsForNpub(npub)` finds the folded groups.
4. **Marmot group id hex** — the key for everything core-owned:
   `unreadByChat`, `chatSnapshotMessagesByChat`, `chatSnapshotLatestByChat`,
   `conversation_summary`, `markConversationRead`.
5. **Duplicate direct groups** — one peer can legitimately have several direct
   Marmot groups (both sides created one). `duplicateDirectMarmotChats` folds
   them into one row; per-group state must be summed/unioned across all of them.

**The one safe resolver is `transcriptGroupIds(chatId)`**
(`SonarAppState.kt`): it returns the folded group-id list for *both* kinds
(direct groups for a Marmot chat id; npub/alias-resolved groups for a `mesh:`
id). If you are about to index a group-keyed map with a chat id, route through
it. `directMarmotChatIds` only handles kind 1→4 when the chat id **is** a group
id — it returns the literal `mesh:` string for mesh chats (that was divider
bug #1: `unreadByChat["mesh:…"]` is always null, so mesh chats read 0 unread).

iOS equivalents: `marmotGroupId(_:)` (handles the `marmot:` route prefix, the
conversation-id map, and fingerprints), `resolvedSonarProfile(_:)` +
`marmotGroup(forNpub:)` for the npub bridge, `directMarmotGroups(matchingGroupId:)`
for duplicate folding.

## Staged hydration: the feed is not complete at first paint

Both kinds obey the Signal-Comparable Performance Rule — paint from local state
synchronously, never block on relays — but they stage it differently, and this
asymmetry is divider bug #2:

**Pure Marmot open** (`openChat`):
1. *Sync*: paint the cached snapshot page (`chatSnapshotMessagesByChat`,
   bounded to `TRANSCRIPT_PAGE_SIZE`). The snapshot is maintained from the same
   core index that owns unread counts, so it **already contains the newest
   rows** — including whatever is unread.
2. *Async*: replace with the bounded DB cursor page (+ echo/media merges), then
   once more after `refreshChats()`.

**Mesh-folded open** (`openDm`):
1. *Sync*: paint the **BLE window only** (`refreshMeshTranscriptWindow` over
   `MessageStore`). If the person mostly talks over White Noise, this window is
   stale or even empty.
2. *Async*: `refreshOpenDm` loads the Marmot legs (`marmotMessagesForPeer`),
   merges them with the BLE rows, publishes, refreshes the chat list, merges
   again.

Consequence: **for a mesh chat, anything computed against the first published
feed is computed against a transcript that is missing the White Noise rows —
which are exactly the unread/newest ones.** The unread divider froze its anchor
on an old BLE row, and the tail-following logic then chased the async merge to
the bottom, leaving the divider off-screen. Even a *fully-read* mesh chat
visibly jumped: it opened anchored at the BLE tail (an old message), then
snapped down to the true tail when the White Noise leg merged.

The primary fix is to make the mesh first paint **complete**, not partial:
`openDm` (and `restoreTranscriptSession`) now seed the White Noise leg
synchronously from the same `chatSnapshotMessagesByChat` snapshot the chat-list
preview uses — merged with the BLE window — so the first frame already holds the
newest rows, exactly like a pure Marmot open. The catch-up gate below remains as
a safety net for a stale/incomplete snapshot.

The guard for this is `latestKnownMessageSecs(chatId)` (Compose) /
`expectedNewestMessageDate(_:)` (iOS): the newest timestamp the core index
knows across the folded groups. Position-sensitive logic must wait until
`feed.maxOf { tsSecs } >= latestKnownMessageSecs(chatId)` before trusting the
feed, and must suppress competing tail-scrolls while it waits (see
`unreadAnchorPending()` in `ChatScreen` and the `onChange(of: msgs.count)`
gating in `SNMsgList`).

iOS has the same staging (`openedDM` → `loadLocalWhenConnected` →
`loadLocalPage` per folded group) plus one extra trap: the published
`unreadByGroup` map **lags cold launches** (it fills on the next summaries
refresh). Open-time captures must fall back to reading
`service.conversationSummaries()` directly.

### The snapshot is not uniformly real (synthetic chat-list rows)

`chatSnapshotMessagesByChat` is **not** all transcript rows. Only the newest
`LOCAL_SUMMARY_CHAT_LIMIT` (5) chats get real message rows from
`recentMessagePages`; every chat below that carries a **synthetic placeholder**
minted from the core conversation index with id
`summary:<groupIdHex>:<latestAtSecs>:<messageCount>` — enough to render a
chat-list subtitle, and nothing more.

A placeholder's id is not an event id, so it can never dedupe against the real
row a bounded page later brings. Feeding one into a transcript renders a
**permanent duplicate bubble**, and the feed growing by it is itself a visible
jump. Always strip them with `withoutSyntheticSummaryRows()` before seeding
transcript state. This is a nasty one because it is position-dependent: the same
code path works for a chat in the top 5 and breaks for the 6th
(`605fa1992` — Sara D worked, Vincenzo-Mac showed the same message twice).

Note `refreshTranscriptGroupWindow`'s fallback also reads this snapshot when the
cursor page read fails; the same rule applies there.

## Read-marking and capture ordering

Opening a chat zeroes the core unread counter. Any feature that needs the
pre-open unread state must capture it **before** the open path runs:

- Compose: `captureOpenChatUnread` runs inside `openChat`/`openDm` *before*
  `markConversationRead` fires; the captured value lives in
  `openChatUnread`/`openChatUnreadAnchor` while the chat is on the nav stack.
- iOS: the capture runs in `push(.dm)` — **navigation time** — because SwiftUI
  fires a child view's `onAppear` before its parent screen's, so any capture in
  the screen's `onAppear` loses the race against the list's first layout.

Read-marking itself is symmetric with the resolver: `openChat` marks
`directMarmotChatIds`, `refreshOpenDm` marks the npub-resolved groups. If you
add state keyed "per conversation", clear/capture it over the **same group set**
the read-marking uses, or the two will disagree for one of the two chat kinds.

## Checklist for touching conversation code

1. **Which id do I hold?** If it can be a `mesh:` route id, resolve through
   `transcriptGroupIds` (Compose) / `marmotGroupId` + npub bridge (iOS) before
   indexing any group-keyed map.
2. **Is that snapshot row real?** `chatSnapshotMessagesByChat` mixes real rows
   (top 5 chats) with synthetic `summary:` chat-list placeholders. Strip them
   with `withoutSyntheticSummaryRows()` before anything but a list subtitle.
3. **Sum across folded groups.** One person ⇒ possibly several group ids.
   Reading only one group's entry silently breaks duplicate-group peers.
4. **Don't trust the first feed of a mesh chat.** Gate position/count logic on
   the catch-up check; assume one or more async merges will follow first paint.
5. **Capture before the open path mutates.** Unread counts, badges, and any
   "state at open" must be read before `markConversationRead`/`openedDM` runs
   (on iOS: at navigation time, not `onAppear`).
6. **Test with BOTH kinds.** A pure Marmot chat and a mesh-folded chat (peer
   with BLE history + White Noise account). The bug that motivated this doc
   shipped green because it was only exercised against pure Marmot chats.
7. **Both platforms.** The Compose and SwiftUI stores mirror each other
   (`SonarAppState.kt` ↔ `SonarAppStore.swift`); a fix landing on one side is
   the most common way conversation bugs return (see `docs/REGRESSIONS.md`).

## Code map

| Concern | Compose (`apps/sonar/…/chat/bitchat/sonar/`) | iOS (`ios/bitchat/Views/…`) |
|---|---|---|
| Open paths | `SonarAppState.openChat` / `openDm` | `SonarAppStore.openedDM`, `push(.dm)` |
| Id folding | `transcriptGroupIds`, `canonicalMeshPeerId`, `meshPeerAliases`, `duplicateDirectMarmotChats` | `marmotGroupId`, `directMarmotGroups(matchingGroupId:)`, `marmotGroup(forNpub:)` |
| Unread source | `unreadByChat` (from `SonarCore.conversationSummaries()`) | `MarmotChatModel.unreadByGroup` (lags; direct read: `unreadCount(forGroups:)`) |
| Catch-up gate | `latestKnownMessageSecs` | `expectedNewestMessageDate` |
| Transcript UI | `ChatScreen` in `App.kt` (feed, anchor, `TranscriptTailPinning`) | `SNMsgList` in `SonarComponents.swift` (`sn-bottom` sentinel, `sn-unread`) |
| BLE rows | `MessageStore`, `refreshMeshTranscriptWindow` | `ChatViewModel` private chats |
| Marmot rows | `marmotMessagesPageForChat`, `marmotMessagesForPeer` | `MarmotChatModel` / `ConversationViewState` |
| Send transport pick | `sendDmAuto` | `sendDm` |

Related reading: the Signal-Style Conversation Design Notes and Fix What We
Break Rule in `CLAUDE.md`, `docs/REGRESSIONS.md` (repeat-offender files), and
`docs/PERFORMANCE.md` (why first paint must stay local).
