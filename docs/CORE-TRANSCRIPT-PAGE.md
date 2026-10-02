# The transcript page is a core screen model

Part of the Bitkey stage-1 move (`sonar-core` computes each screen's model,
SwiftUI and Compose render it). The chat list (#647, #651), opening a chat
(#652) and the row fields (#653) are already core-owned. This note covers the
transcript **page**: which White Noise rows a conversation shows, in which
order, and where the next page starts.

## What each app did

A conversation can span several MLS groups: duplicate 1:1s fold into one chat
(R-003), and a mesh chat folds in the peer's White Noise groups. Both apps kept
one window **per group** and merged them themselves:

- Compose: `transcriptWindows[groupId]` (`refreshTranscriptGroupWindow`,
  `loadOlderMessages`) plus `transcriptSourceIdsNeedingExpansion`, the k-way
  frontier that refuses to publish an older page until every group has a full
  page behind the oldest visible row.
- iOS: `messagesByGroup[groupId]` (`loadLocalPage`, `loadOlderLocalPage`)
  plus `SNConversationTranscriptWindow.sourceIDsNeedingExpansion` over the same
  per-group sources.

The two merges had drifted: iOS sorted by `Date` and kept the first duplicate,
Compose sorted by whole-second `tsSecs` and kept the last. Each group page also
ran its own quote-parent fill, so a group could not see its twin's rows.

## The core page

`SonarClient::conversation_cursor_page(group_ids, before_secs, before_id, limit)`
→ `ConversationPage { rows, has_more }`.

- **One order:** `(created_at DESC, event_id DESC)`, the order
  `messages_cursor_page` already guarantees per group (stable across pages,
  also inside one second).
- **Merge:** read `limit + 1` rows from each group with the same exclusive
  cursor, merge, de-duplicate by event id, keep `limit`. Any row of the global
  top `limit` is inside its own group's top `limit`, so this is exact. No
  frontier bookkeeping is left for the apps across White Noise groups.
- **`has_more`:** true when the merge held more than `limit` rows.
- **Cursor:** the last row of the page, the same tuple the per-group page took.
- **Rows carry `group_id_hex`**, so an app knows which group to react, reply
  or retry into without searching its windows.
- **Quote chips** search the whole set (`fill_reply_parents` with the page's
  groups), under the same 16-read budget for the whole page.
- **The set comes from the app.** For White Noise chats it is the core row's
  `group_ids`; for a mesh chat, the peer's groups the app already resolves. The
  core does not guess it.
- **Errors (R-018):** a read that fails for every group is an error, never an
  empty page. A group that fails while others answer is skipped and logged, so
  one removed group cannot blank the chat. That group's rows are then missing,
  as they were before when its own window failed.

## What stays in the apps

- **Non-core sources:** mesh rows, payment activity and call logs (iOS), mesh
  rows and call records (Compose). The apps still merge these with the single
  White Noise source. The k-way frontier logic stays, but with two sources
  where it had one per group plus mesh.
- **Optimistic echoes:** echo reconciliation stays in each app until core owns
  pending sends.
- **Pinning and retention:** pinning to the older edge and the 500-row
  retained window stay too. They are view state.

## Adoption

1. **Core + FFI** (shipped): `SonarNode.conversationCursorPage(groupIds,
   beforeSecs, beforeIdHex, limit)` → `ConversationPageInfo { messages,
   hasMore }`; `MessageInfo.groupIdHex` on every row.
2. **Compose** (shipped): `transcriptWindows` holds one window per White Noise
   group **set** (`transcriptWindowKey`), filled by `conversationCursorPage`
   for the newest page and for older pages. `loadOlderMessages` weighs that one
   source against the mesh rows. `freshCanonicalByGroup` and the reaction-tally
   overlay are split by `SonarMsg.groupId`, so echo reconciliation (R-001,
   R-025) still sees per-group rows. `marmotGroupIdForReaction` reads the row's
   group.
3. **iOS** (shipped):
   - **Shared paging state:** the folded set shares one cursor, has-older flag, loading guard and older-edge pin in `MarmotChatModel`, keyed by `localTranscriptPageKey`. That key is the sorted set from core's chat-list rows, or the group id alone.
   - **Both loads read the merged page:** `loadLocalPage` and `loadOlderLocalPage` read `conversationCursorPage` for the set. They compute the window over the union of the set's rows and split it back into `messagesByGroup` by each row's `groupId`, so echoes, side-effect scans and unread still read per group.
   - **One source per set:** `dmMsgs` stamps every White Noise row with the set's key as its source id, and `dmTranscriptSources` reports one source per set. `SNConversationTranscriptWindow` therefore sees a single boundary, which is what its per-source uncovered-prefix rule needs.
   - **Rows keep their group:** `SNMessage.marmotGroupID` holds the row's own group, so reactions go to the group that holds the message.
   - **Summary refresh:** for a set, the summary refresh may move the cursor only newer (a trim). A quiet group's newest rows can sit below the merged window, and dropping the cursor to them would skip the other groups' rows.
   - **A single-group chat pages exactly as before:** its key is its group id and its page is that group's page.
