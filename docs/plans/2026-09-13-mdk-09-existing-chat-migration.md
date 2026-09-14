# Plan: keep existing chats through the MDK 0.9.14 port

Date: 2026-09-13
PR: [#613](https://github.com/hedwig-corp/bitchat-to-sonar/pull/613)
Parent plan: [#327](https://github.com/hedwig-corp/bitchat-to-sonar/issues/327) / `docs/plans/2026-07-18-mdk-09-multi-device.md`

This is the missing Stage 1 storage step. The protocol port is already on
`cursor/mdk-v0.9.14`. Without this path, shipping 0.9.14 as a silent replace
would lock existing users out of their White Noise / Marmot transcripts.

## What is not retrocompatible

A 0.8 Sonar install and a 0.9.14 install **cannot decrypt each other's MLS
traffic**. The Marmot wire format moved `0xf2ee` → `0xf2f1` (what White Noise
iOS already speaks). That is a protocol flag-day, not a schema bump.

SQLCipher keying also changed:

| Store | `PRAGMA key` | Schema |
| --- | --- | --- |
| MDK 0.8 (`mdk-sqlite-storage`) | `"x'<hex>'"` raw key | `groups` / `messages` / OpenMLS tables |
| MDK 0.9 (`storage-sqlite`) | `'<hex>'` passphrase | account-device session |

`storage-sqlite` cannot open or upgrade a 0.8 file. Treating the open error as
"wipe and recreate" is forbidden by the Account Key Durability Rule.

Mesh / BLE chats are a different store (`MessageStore`). They are not in the
MDK file and are not affected by this port.

nsec, wallet restore material, and the conversation-index SQLCipher file stay
on the host keychain / `x'<hex>'` sidecar. Those must not be rotated.

## Decision: decrypt-and-move local history; do not import MLS groups

Stage 0 asked: in-place schema upgrade vs decrypt-and-replay?

**Chosen: decrypt-and-move plaintext only.**

Reasons:

1. The 0.8 `messages` table already holds decrypted application events
   (`kind = 9` chat rumors, `content` plaintext). No 0.8 engine crate is
   required to read them.
2. MLS secrets, epochs, and welcomes in that file are 0.8-wire. Importing
   them into a 0.9 session would produce groups that cannot talk to anyone
   on 0.9 / White Noise, and cannot talk to remaining 0.8 peers either once
   this install has moved.
3. Dual-stack (keep a 0.8 engine beside 0.9 in one binary) is the only way
   to keep *sending* into an old group during a mixed fleet. That is a
   separate, larger change (two OpenMLS graphs, two publish paths, two
   conversation ids). It is not required to keep users able to **read**
   what they already have.

What the user keeps after upgrade:

- Same npub / nsec (keychain).
- Same wallet restore path.
- Same conversation-index file (chat-list rows, unread, latest preview).
- Full local Marmot transcript, copied onto `.sonar-transcript.json`.
- The original 0.8 SQLCipher file, renamed `*.mdk08.bak` (never deleted
  by the migrate path).
- Account backups taken after upgrade (v2) include those sidecars, so
  nsec restore still paints the recovered transcript.

What the user does **not** keep automatically:

- The ability to send into the old 0.8 MLS group. That group is dead on
  this device once the 0.9 store is the live engine.
- Media **decrypt** when the 0.8 store has no `encrypted-media` exporter
  secret (pre-V005 unlabeled rows are MIP-03 `group-event` only). When
  the labeled secret is present it is copied onto
  `.sonar-historical-exporter-secrets.json` and recovered blobs decrypt.
  Otherwise the attachment stays a non-retryable “older Sonar” row.
- The ability to *accept* a stored 0.8 welcome event (0.8 wire). Pending
  `welcomes` rows are listed as recovered chats (name + welcomer /
  admins) so the user can resume on a new 0.9 group after the peer
  updates.

## Runtime path (implemented on this PR)

`MarmotEngine::persistent`:

1. Try MDK 0.9 open (passphrase key, `defer_group_hydration`).
2. If the file is plaintext `SQLite format 3`, wipe + recreate (existing
   self-heal).
3. If 0.9 open fails and the file exists:
   - Open with the 0.8 raw key.
   - If `messages` is readable, copy group titles, resume members, pending
     `welcomes` (name + welcomer/admins, not the 0.8 event), labeled
     `encrypted-media` exporter secrets, and the newest 80 `kind = 9`
     rows per group onto the transcript sidecar.
     First paint ranks on `mls_group_id` / `id` / `created_at` only, then
     joins `content` / `tags` / `event` for the winners (`ROW_NUMBER`
     window, or per-group `ORDER BY created_at DESC LIMIT 80` if the
     window prepare fails). `connectLocal` must not project older payload
     blobs.
   - Rename the 0.8 file (and WAL/SHM) to `*.mdk08.bak`.
   - Create a fresh 0.9 store at the original path.
   - Copy leftover older rows from the bak in bounded pages (400
     payloads per tick) on idle `ensure_subscriptions` / `sync`.
     Scrolling a recovered chat (`messages_page` / `messages_cursor_page`
     past the local window) fills that conversation from the bak
     without draining every other chat. `messages()` drains every
     page so the full-history API stays complete. Newest first-paint
     pages that already fit do not.
   - If 0.9 create fails, rename the 0.8 file back. Never delete it.
   - A later 0.9 open that already has `*.mdk08.bak` runs a **one-shot**
     metadata backfill (pending welcomes + labeled `encrypted-media`
     secrets + group names/members). It does not join leftover chat
     payloads. The migrate marker records `metadata_backfill=complete`
     so cold start does not reopen the bak every launch.
4. Wrong key / unknown file: return `protocol migration required`. Do not
   wipe, do not quarantine.

`ConversationIndex::materialize_from` seeds empty index rows from
recovered group ids. A non-empty upgraded index only adds **missing**
recovered rows (`seed_missing_recovered`) so unread counts on existing
chats are not reset. Chat-list first paint does not wait on live MLS
groups (Signal-comparable / XChat startup).

Resume peers come from transcript senders **and** the 0.8
`admin_pubkeys` / every `messages.pubkey` sidecar
(`.sonar-historical-members.json`). A DM you only ever sent into still
has the other npub after the flag-day.

Guarded by:

- `mdk08_migrate::tests::extracts_plaintext_chat_and_ignores_non_chat_rows`
- `mdk08_migrate::tests::wrong_key_is_not_a_0_8_store`
- `persistence::mdk08_store_decrypts_and_moves_plaintext_without_wiping`
- `persistence::mdk08_first_paint_defers_older_rows_until_remainder`
- `mdk08_migrate::first_paint_keeps_newest_window_and_marks_truncated`
- `mdk08_migrate::first_paint_window_sql_ranks_ids_without_payload_columns`
- `mdk08_migrate::first_paint_skips_invalid_and_non_chat_rows_in_the_window`
- `mdk08_migrate::first_paint_per_group_fallback_keeps_newest_window`
- `mdk08_migrate::first_paint_windows_each_group_independently`
- `mdk08_migrate::remainder_candidate_sql_ranks_ids_without_payload_columns`
- `mdk08_migrate::remainder_page_skips_copied_ids_and_reports_more`
- `mdk08_migrate::remainder_page_can_target_one_group_without_clearing_others`
- `mdk08_migrate::remainder_page_skips_omitted_groups`
- `mdk08_migrate::backfill_skips_dropped_groups`
- `persistence::delete_then_remainder_does_not_restore_transcript`
- `persistence::mdk08_store_wrong_key_is_left_intact`
- `marmot::historical_fold_tests::recovered_history_survives_fold_onto_new_group`
- `e2e::recovered_08_chat_resumes_on_a_new_09_group_through_a_relay`
- `e2e::recovered_08_group_resumes_on_a_new_09_group_through_a_relay`
- `e2e::recovered_08_group_resumes_with_whichever_peers_have_updated`
- `e2e::recovered_08_group_adds_a_member_who_updates_later`
- `e2e::recovered_08_group_adds_late_member_on_sync_without_a_local_send`
  (pins `ensure_subscriptions`, the host idle path)
- `mdk08_migrate::outbound_only_chat_keeps_admin_peer`
- `mdk08_migrate::copies_imeta_and_p_tags_from_stored_message_tags`
- `marmot::historical_fold_tests::recovered_08_media_is_unavailable_even_with_imeta`
- `client::tests::fetch_media_rejects_recovered_08_attachments_before_http`
- `client::tests::fetch_media_with_stored_08_exporter_is_not_unavailable`
  (pins `fetch_media` + iOS `fetch_media_to_file` after a labeled secret is stored)
- `e2e::recovered_08_outbound_only_chat_resumes_from_admin_pubkeys`
- `conversation_index::copy_summary_promotes_recovered_row_onto_live_id`
- `conversation_index::copy_summary_adds_historical_unread_onto_live_that_already_has_unread`
  (`maybe_fold_new_group` can land on a live 0.9 DM that already has a
  badge; `conversation_summaries()` hides the historical sibling, so
  unread must be **added** onto live and then zeroed on hist or the
  host divider undercounts recovered missed messages)
- `client::tests::incoming_09_dm_welcome_folds_recovered_08_direct_chat`
  (auto-accepted GroupUpdated and parked-then-accept must call
  `maybe_fold_new_group`; otherwise a peer-started 0.9 DM leaves the
  0.8 row listed and a send on that id mints a second 0.9 group)
- `client::tests::incoming_09_room_welcome_folds_recovered_08_room`
  (accepting a 3+ 0.9 room whose other members match the recovered
  sidecar folds history)
- `client::tests::incoming_09_named_pair_welcome_folds_recovered_named_room`
  (auto-accepted 2-person `create_group("standup")` folds a recovered
  named pair on unique name + exact member match; White Noise DMs
  without `sonar.direct-dm.v1` take this path)
- `client::tests::incoming_09_named_pair_welcome_skips_when_names_differ`
- `client::tests::incoming_09_named_pair_welcome_does_not_fold_three_member_room`
  (R-045: a recovered 3-person standup must not fold onto a 2-person
  live standup just because the names match)
- `client::tests::incoming_09_named_pair_second_welcome_does_not_steal_fold`
  (already-folded hist must not move onto a second matching 0.9 group)
- `client::tests::incoming_09_room_welcome_folds_when_live_is_subset_of_recovered`
  (incoming mixed resume matches `resolve_send_group`: live others
  may be a unique subset of the recovered roster; leftovers stay
  late-resume invites)
- `client::tests::incoming_09_room_welcome_skips_ambiguous_overlapping_rooms`
  (two recovered rooms that both contain the live others, with no
  unique name, must not merge)
- `client::tests::incoming_09_dm_welcome_does_not_fold_recovered_room`
  (R-045 at the incoming-welcome call site: welcomer-only known
  members must not absorb a recovered room into a 1:1)
- `ConversationFoldTest.recoveredAndResumedDirectChatsRenderOnceByPeer`
- existing `wrong_key_cannot_open_existing_db` / `self_heals_an_unencrypted_legacy_database`
- `account_backup::decode_v1_package_has_empty_sidecars`
- `account_backup::seal_open_roundtrip_keeps_recovered_sidecars`
- `account_backup::staged_restore_replaces_outgoing_sidecars`
- `account_backup::preview_lists_recovered_chats_when_index_is_missing`
- `persistence::mdk08_account_backup_preserves_recovered_transcript`
- `persistence::mdk08_account_backup_preserves_remainder_after_restore`
- `persistence::mdk08_account_backup_omits_bak_after_remainder_complete`
- `persistence::mdk08_account_backup_keeps_bak_when_transcript_is_missing`
- `persistence::mdk08_unreadable_bak_keeps_remainder_pending`
- `mdk08_migrate::leftover_bak_needed_follows_transcript_not_just_the_marker`
  (also pins `bak_needed_for_backup` until `metadata_backfill=complete`)
- `mdk08_migrate::empty_named_group_is_kept_for_resume`
- `mdk08_migrate::pending_welcome_is_kept_for_resume`
  (stores `member_count` so a 3+ pending room does not `start_dm`)
- `mdk08_migrate::named_joined_room_description_is_copied`
- `mdk08_migrate::processed_welcome_member_count_survives_extract`
- `persistence::mdk08_named_room_with_one_known_peer_is_not_direct`
- `mdk08_migrate::labeled_media_exporter_secret_is_copied_unlabeled_is_not`
- `marmot.rs::recovered_08_media_decrypts_with_stored_exporter_secret`
- `persistence::mdk08_pending_welcome_is_listed_for_resume`
  (also pins nsec restore of the name + welcomer sidecar)
- `persistence::mdk08_media_exporter_secret_survives_migrate_and_backup`
- `mdk08_migrate::metadata_backfill_is_one_shot_after_the_marker_lands`
- `persistence::mdk08_bak_backfills_welcome_and_media_secrets_on_reopen`
  (pins `SonarClient::connect` → `conversation_summaries()` on a non-empty
  0.8-era index: pending welcome + welcomer resume peers land, existing
  unread is not reset. Also pins host stage→commit nsec restore of that
  blob and Settings preview listing a bak-only invite)
- `persistence::mdk08_v1_backup_restores_and_migrates`
- `account_backup::write_read_package_files_roundtrips_outbox_and_sync`
- `marmot::historical_fold_tests::historical_fold_survives_account_backup_restore`
- `marmot::historical_fold_tests::delete_live_group_purges_folded_historical_history`
- `marmot::historical_fold_tests::delete_live_group_forgets_historical_name_sidecar`
- `account_backup::preview_omits_dropped_recovered_chats`
- `mdk08_migrate::forget_historical_metadata_drops_deleted_sidecar_rows`
- `ConversationFoldTest.foldedOpenUnreadAndTranscriptWindowRemountOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalRoomRemountsOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalMuteMovesOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalComposerDraftMovesOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalComposerReplyMovesOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalSnapshotMessagesMoveOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalCallLogsMoveOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalPendingEchoesMoveOntoLiveSibling`
- `SonarConversationFoldTests.recoveredAndResumedDirectChatsPreferLiveSendTarget`
  (also pins `snPromotedFoldedPendingMessages`)
- `ConversationFoldTest.foldAliasesDiscoverHiddenHistoricalIdFromLiveSibling`
- `marmot::historical_fold_tests::recovered_history_survives_fold_onto_new_group`
  (also pins `fold_aliases` both directions)
- `ConversationFoldTest.foldedHistoricalVerifiedBlobRecoversOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalVerifiedMovesOntoLiveSibling`
- `ConversationFoldTest.foldedHistoricalSnapshotChatDropsOnceLiveSiblingIsListed`
- `ConversationFoldTest.foldedHistoricalScanWatermarkMovesOntoLiveSibling`
- `SonarNotificationHandoffTest.resolveOpenTargetRemapsFoldedHistoricalIdOntoLiveSibling`
- `e2e::recovered_08_group_resumes_on_a_new_09_group_through_a_relay`
  (also pins `live_fold_target_hex` after the home-list hide)

## Account backup after upgrade

A backup taken **after** the 0.8 → 0.9 migrate is the only copy of recovered
history once the user deletes the app data or restores onto a new phone.
v1 packages carried only `marmot.sqlite` + the conversation index. After
migrate, the live SQLCipher file is an empty-of-history 0.9 session; the
transcript lives in host sidecars and `*.mdk08.bak`.

v2 (`FORMAT_VERSION = 2`) packs those allow-listed suffixes into the
sealed blob. Decoders still accept v1 (empty sidecar list). Restore writes
the sidecars next to the DB, including the staged-restore rename path.
A restore that omits a sidecar deletes the leftover outgoing file so the
previous account's transcript cannot leak across nsec restore.

SQLCipher open for seal/verify tries the 0.8 raw key (`x'<hex>'`) and the
0.9 passphrase (`'<hex>'`) and requires at least one user table. The
conversation index stays on the raw key; the live Marmot file is
passphrase-keyed after migrate.

A **v1 backup taken before upgrade** is only the 0.8 SQLCipher file.
Restore writes those bytes; `MarmotEngine::persistent` runs decrypt-and-move
again. Preview of a v2 blob with no (or empty) index lists recovered chats
from the transcript / historical-groups sidecars so Settings does not say
the backup is empty. A non-empty index is unioned with titles from a
packed `*.mdk08.bak` so a pending invite that never reached the index
still appears in the dry run. Parked invites, dropped-group ids, the outbox, and
sync watermarks travel with v2 so a pending 0.9 send or room resume
survives nsec restore. The quarantined `*.mdk08.bak` plus the partial
migrate marker must be in the blob **while remainder is still pending** —
otherwise restore keeps only the first-paint window. Once leftover rows
are copied onto the transcript, later backups omit the bak so the sealed
blob does not double (cap 400 MiB while bak is still packed). If the
transcript sidecar is missing, the bak is packed even when the marker
says `complete`. If `metadata_backfill` is not `complete`, the bak is
packed even after leftover rows are in the transcript — otherwise an
early 0.9 backup would drop pending welcomes and labeled media secrets
on nsec restore. Remainder ticks still follow leftover rows only, so
idle sync does not reopen the bak after history is copied. An
unreadable bak fails the remainder tick and stays pending — it is never
treated as an empty remainder. The local `*.mdk08.bak` file stays on
disk until a later cleanup release.

## How users keep access after the flag-day

Reading is not enough for a messenger. Sending and receiving with peers
requires a **new** 0.9 / `0xf2f1` group.

### Recommended rollout (no dual-stack)

1. **Ship history migration first** (this PR) and keep the build draft
   until group-scale + the tests below are green.
2. **Flag-day the protocol.** One release speaks 0.9.14 only. Old 0.8
   peers see the existing typed mismatch error (`0xf2f1` vs `0xf2ee`).
3. **Resume chat by npub, not by old group id.** When the user opens a
   recovered conversation and sends, create a new 0.9 DM/group with the
   same peer npub (KeyPackage fetch, XChat-style pending row). Fold the
   new live group onto the historical row using the existing conversation
   unification invariant (`docs/CHAT-TYPES.md`, `docs/REGRESSIONS.md`).
   The old group id stays the history bucket; the new group id becomes
   the send/receive bucket.
4. **Peer still on 0.8.** They cannot decrypt the new group. Show a
   stable "waiting for them to update Sonar" state. Do not silently
   open a second chat. Mesh/BLE still works as the fallback send path
   for folded conversations.
5. **Keep `*.mdk08.bak` until a later cleanup release** so a bad 0.9
   build can be rolled back and the 0.8 file reattached.

This is "decrypt and move the content", then "start a new encrypted
session with the same person". Users do not lose the transcript. They
lose live membership in the old MLS group, which cannot be preserved
without dual-stack.

### Deferred alternative: dual-stack transition window

Keep a 0.8 `mdk-core` reader/sender next to the 0.9 engine for one
release. Old groups stay writable to 0.8 peers; new groups are 0.9.
Reject unless we are willing to:

- pin `mdk-core` / `mdk-sqlite-storage` at `e8cd584` beside
  `cgka-session` 0.9.14
- route send/ingest by per-group protocol tag
- double the welcome/commit test matrix
- accept two wire formats on the same chat list

Do not start this unless White Noise interop and the 0.8 installed base
both have to coexist for a long time. The current decision is flag-day
plus history fold.

## Production test gates (must be green before undraft)

Local / CI:

```sh
cd core
cargo test -p sonar-core --lib mdk08_migrate
cargo test -p sonar-core --lib historical_fold
cargo test -p sonar-core --test persistence
cargo test -p sonar-core --lib account_backup
cargo test -p sonar-core --test e2e recovered_08
cargo test -p sonar-core --test group_invites
cargo test -p sonar-core --lib client::tests
cargo test -p sonar-core --test failed_events
cargo test -p sonar-core --test media
cargo test -p sonar-sim
```

MIP-03: kind-445 commits stay `Buffered` until `advance_group_convergence`
after ~1.1s. Ingest returns `GroupUpdated` and parks the group;
`process_marmot_events` / `sonar-sim` apply the drain off the receive
path. Treating `Buffered` as `Failed` froze incremental `add_members`
at the founding batch.

MDK-bump rule (`docs/GROUP-SCALE-SIM.md`): the v0.9.14 ceiling is **50**
(`--batch 25`). N=100 fails wrapping the next welcome (NIP-44).

```sh
cargo run -p sonar-sim --release -- group-scale \
  --ramp 2,5,10,25,50,100,110,120,130 \
  --mode incremental --batch 25 --chaos --out /tmp/scale-mdk09.json
```

Commit the new ceiling + welcome-size table. A moved ceiling is expected
(`0xf2ee` → `0xf2f1`) and is the signal to re-check White Noise interop,
not a silent pass.

Device / interop (not substitutable by unit tests). In-place replace
only — never uninstall the personal app (Account Key Durability /
Never Uninstall Device Apps). Record pass/fail against this sheet:

| # | Pass | Fail |
| --- | --- | --- |
| 1. **0.8 → this build, same device** | Same npub in Settings; wallet restore material still present (do not print it); `*.mdk08.bak` next to the Marmot DB; recovered Marmot rows on first paint | New npub, missing wallet material, wiped DB, or empty chat list |
| 2. **Open recovered DM + room offline** | History paints with radio off / before relays; scroll past the newest 80 rows loads from bak; typing works; a pending 3-member room that only lists the welcomer stays its own row next to any 1:1 with that person; banners use the room name | First paint waits on relay; bak remainder never appears; room collapses into the welcomer DM |
| 3. **Peer already on 0.9 / White Noise** | Send in the recovered row creates a new 0.9 group; old transcript stays; home list stays one row; peer decrypts only the new traffic | Split chat, lost history, or peer cannot decrypt the new send |
| 4. **Peer still on 0.8** | Send shows “Waiting for them to update Sonar”; no second chat; no wipe; mesh/BLE still sends if the conversation is folded | Silent send, new empty chat, or account wipe |
| 5. **Mixed room** | Resume includes whoever already published a 0.9 KeyPackage; leftover members are invited on the next idle `ensure_subscriptions` or send; 3+ rooms stay pending invites, 2-member welcomes auto-join | Room becomes a DM; leftover members never invited |
| 6. **Sonar 0.9.14 ↔ White Noise iOS 0.9** | DM and group both directions, including N≈25 (welcome ~38.7 KB vs 0.8’s 27.8 KB) | Either direction fails, or N≈25 cannot join |
| 7. **Cold-start** | Debug + `SONAR_BENCH_NSEC`; `t0→t4` vs `docs/PERFORMANCE.md`; first-upgrade extract is local disk on `connect()` (newest 80/group, then 400/tick from bak), not on the relay path | Sync or migrate sits on the critical path; large 0.8 DB guessed rather than measured |

## Surfaces

| Surface | History | Live 0.9 send | Gap |
| --- | --- | --- | --- |
| Rust core | decrypt-and-move (this PR) | `send_*` resumes via `start_dm` / `create_group` and records a fold. Resume peers include 0.8 `admin_pubkeys` so outbound-only chats can restart. Direct chats auto-join; recovered rooms use the existing pending-invite accept path, include whoever already published a 0.9 KeyPackage, and `add_members` leftover peers on the next send **or** background `sync` / `ensure_subscriptions` | none |
| Conversation index | preserved + seeded from sidecar | fold copies the recovered row onto the live id and **adds** historical unread onto live (then zeros hist so a second copy cannot double-count); `conversation_summaries()` hides the historical sibling; `mark_conversation_read` clears the whole fold family | none |
| Compose (`apps/sonar`) | Recovered rows stay in `groups()` until resume; after fold, FFI hides the historical sibling. Live `member_npubs` unions the recovered roster (`display_members`) so the member sheet / mentions stay populated after remount. `GroupInfo.is_direct` keeps rooms off the 1:1 npub fold. First-paint snapshot now persists `isDirect` (6th field) so a two-member recovered room does not fold onto the welcomer DM before `chats()` returns. Pre-`isDirect` blobs default **not-direct** in memory so the room stays visible; startup rewrite of old blobs omits the flag until `groups()` returns so invented `false` is not durable. A joined named room with only one known peer stays a room (`historical_resume_is_direct` matches live `group_is_direct`) and keeps the room title (`marmotChatDisplayTitle` / `snMarmotChatDisplayTitle` — the 1:1 profile path is `isDirect` only). Host remounts an open historical id onto `live_fold_target` and copies mute / composer draft / reply / verify / call logs / unread-at-open / transcript window / in-flight send echoes onto the live sibling. FFI `fold_aliases` lets a listed live id name its hidden 0.8 siblings so the host fold map hydrates on first launch without a leftover snapshot row. A persisted `sonar.historicalFolds` map drops a recovered snapshot row on the next cold start once the live sibling is already listed. After a KeyPackage miss, `recoveredChatHasLiveFoldSibling` treats a hist→live binding as the live sibling even when FFI has hidden the 0.8 id (listed duplicates go back to 1; rooms never have listed 1:1 duplicates). Remount **drops** the waiting-banner flag instead of copying it onto the live id. Shade taps inherit the still-listed 0.8 sibling's name/members, then `adoptedListedChatTitle` replaces a captured "Group chat" stub once the live row lists. | send prefers newest duplicate; toast/banner if KeyPackage missing — cleared once a live sibling exists; recovered 0.8 attachments show a non-retryable “older Sonar” state | none |
| iOS (`ios/`) | same (`MarmotGroup.isDirect` in the Codable snapshot; live `memberNpubs` from `display_members`). Old snapshots without the key default not-direct in memory. `SNMarmotChatSnapshotCache.load` strips leftover message bodies without re-encoding groups, so invented `isDirect=false` is not stamped durable before FFI `groups()`. Mute / draft / reply / verify / call-log / unread-at-open / transcript-window / in-flight send-echo promotion and open-chat remount match Compose. Cold-start snapshot load collapses folded historical ids via `sonar.historicalFolds.v1`. `snRecoveredChatHasLiveFoldSibling` + remount-drop of `recoveredChatNeedsUpdate` match Compose so a successful resume clears “Waiting for them to update Sonar”. Title is derived each render (`marmot.title(for:)`); `marmotGroup(byId:)` walks `snListedOrFoldedSiblingGroupId` so a hidden 0.8 id still resolves the listed sibling. | same | none |
| Mesh | untouched | untouched | none |

Resume-chat fold: recovered 0.8 rows appear in FFI `groups()` with
members inferred from the transcript. A send on that id creates a new
0.9 group with the same peer npubs, records
`.sonar-historical-folds.json`, and `messages()` unions both ids so
history is not wiped or split. After the fold, FFI `groups()` omits the
historical sibling (same as `conversation_summaries()`) so the home list
stays one room row — hosts paint `chats()` / `groups()`, not the index.
Live `GroupInfo.member_npubs` comes from `display_members` (fold-family
union of live MLS + recovered 0.8 rosters) so a remounted room still
lists people who have not joined 0.9 yet. Persist-folds can hide hist
from the host list before core `fold_family` exists; host collapse then
copies the recovered name / roster onto the live row
(`collapsedFoldedSnapshotChats` / `snCollapsedFoldedSnapshotGroups`)
without touching `isDirect` (R-045). Room leave / mesh-folded delete
then `deleteChat` the persist-folds hist sibling after `leaveGroup(live)`
(`leaveFamilyCorePurgeIds` / `snLeaveFamilyCorePurgeIds`) so a leftover
0.8 row cannot resurrect on the next cold start. Load-older on the listed
live id waits if the hidden 0.8 sibling is already paging
(`loadOlderBusyRetryShouldWait` / `snLoadOlderBusyRetryShouldWait`).
Compose quote-jump retries on `quotedJumpRetryToken` (size + oldest +
newest), not `feed.size` alone, so a 500-row bak slide still finds a
recovered 0.8 parent. `members()` / `group_is_direct`
stay live-session only so leftover peers remain late-resume invites.
If the user is sitting in that recovered transcript when resume lands,
Compose and iOS remount the open chat id onto `live_fold_target` so
member/title lookups do not miss the hidden row; in-flight send still
resolves through the fold map. Remount also copies the unread-at-open
count / jump target and the in-session transcript window
(`transcriptWindows` / `freshCanonicalByGroup` on Compose;
`unreadCountAtOpenByDM` / `jumpMessageIdAtOpenByDM` /
`ConversationViewState` plus the Marmot older-edge cursor on iOS) so
resume does not treat the live sibling as a fresh open and snap a
scrolled recovered chat back to the tail. iOS remount does **not** call
`openedDM` (that hydrates newest-page). An in-progress media confirmation
sheet is rebound onto the live id so Send does not lose the staged
files. An in-flight send echo on the hidden id is merged onto the live
sibling (Compose `pendingSendEchoes`, iOS `pendingMarmotMessagesByChat`
plus queued `pendingDirectMarmotSends` / `pendingMarmotGroupSends`) so
the first resume send does not vanish from the remounted transcript.
Trill cooldown moves with the same remount. Recovered transcript rows
merge onto a live sibling that already has the new send, so a one-row
live cache cannot hide the 0.8 history. Room resume copies the 0.8
`groups.description` onto `create_group_with_description` (never the
DM marker). A mute on the recovered id is copied onto
the live sibling when the historical row disappears, so resume does not
start notifying a chat the user already silenced. An in-progress composer
draft or reply target on that hidden id is copied the same way — including
when the user already left the recovered transcript — so the live composer
is not empty after fold. Remount of an open chat does not overwrite a
non-empty live draft. Host snapshot / in-memory transcript rows on the
hidden id are copied onto the live sibling so home preview does not go
blank between `groups()` hide and the next bounded page. A notification
tap whose payload still names the hidden 0.8 id remaps onto
`live_fold_target` instead of toasting that the chat is gone. Cold start
does that from the persisted hist→live blob (`sonar.historicalFolds` /
`sonar.historicalFolds.v1`) when FFI is not up yet — a shade tap must
not wait on `connect()` to open a chat the snapshot already listed.
Compose now remaps and opens that live id even when it is not yet in
`chats()` (iOS already did via `snNotificationOpenGroupId` / `openDM`).
A stub row is not-direct so a recovered room cannot fold as a 1:1.
Compose captures `Screen.Chat.name` at push; after `refreshChats()` lists
the remapped row, `adoptedListedChatTitle` replaces a stub "Group chat"
title. iOS derives the title from `marmot.groups` / `marmot.title(for:)`
each render (no captured stub). Both hosts resolve title / members /
verify / call / pay chrome through a bidirectional fold-sibling lookup
(`listedOrFoldedSiblingChat` / `snListedOrFoldedSiblingGroupId`) so a
hidden 0.8 id or an unlisted live id still sees the other listed sibling.
Persisted
call-log rows on the hidden id are merged onto the live sibling so resume
does not drop the recovered call history. A safety-number verify on the
hidden id is copied onto the live sibling so resume does not drop the
checkmark. Call/pay/notification scan watermarks and seen-ids move with
the fold so recovered history is not replayed as new traffic on the live
id. Hosts persist hist→live bindings and drop a recovered snapshot
row on the next cold start when the live sibling is already listed, so an
older mid-PR snapshot that still has both ids does not flash two room
rows. Leave/delete of the live sibling
purges the whole fold family so a later `start_dm` with the same peer cannot
resurrect a conversation the user already removed. Hosts also drop the
hist→live blob (`sonar.historicalFolds` / `sonar.historicalFolds.v1`) and
persist the chat snapshot without the family immediately, so a mid-session
delete cannot leave a recovered 0.8 row for the next first paint.
Core also forgets recovered name/member/description/count/secret sidecars
for that family — disk and the in-memory maps, so a same-session
`historical_group_name` lookup cannot seed a chat the user already left. Settings restore preview subtracts `.sonar-dropped-groups.json`
ids from both the historical-groups sidecar and packed `*.mdk08.bak` titles,
so a backup taken after Leave does not list a chat the user already removed.
Remainder ticks from `*.mdk08.bak` also omit `.sonar-dropped-groups.json`
ids: Leave clears the transcript but the bak is never rewritten, so an idle
`ensure_mdk08_remainder` / `messages()` drain on any other chat must not copy
those rows back. `recovered_group_ids` / `seed_missing_recovered` skip dropped
ids so a leftover in-memory title cannot recreate the chat-list row on the
next `connectLocal`. Bak metadata backfill (`metadata_backfill=v2` for older
markers) also omits dropped ids so a later open cannot restore forgotten
names/members/secrets. `conversation_summaries` omits dropped ids and heals
a leftover index row (crash between core purge and index remove) so unread
probes cannot keep a deleted recovered chat. Ingest after Leave
(`store_chat` / `persist_session_effects` / drain `Incoming::Message`)
also skips dropped ids so relay replay of an old kind-445 cannot rewrite
the transcript, reindex the home row, or toast a chat the user already
left. `purge_fold_family` also drops parked invites for that family, and
`park_invite` / welcome ingest refuse a dropped MLS id so a declined or
left room cannot reappear as "Group chat · invite". Hosts persist
hist→live bindings into the App Group mute path so a muted recovered
chat stays silent when the next push names the live 0.9 id. Pins:
`mdk08_migrate::remainder_page_skips_omitted_groups`,
`mdk08_migrate::backfill_skips_dropped_groups`,
`persistence::delete_then_remainder_does_not_restore_transcript`,
`marmot::historical_fold_tests::delete_live_group_forgets_historical_name_sidecar`
(also pins in-memory `historical_group_name` / description are gone after Leave),
`marmot::historical_fold_tests::store_chat_skips_dropped_groups`,
`marmot::historical_fold_tests::reopen_omits_dropped_transcript_rows`,
`marmot::historical_fold_tests::purge_fold_family_clears_parked_invites`,
`marmot::historical_fold_tests::park_invite_skips_dropped_groups`,
`client::tests::conversation_summaries_omit_and_heal_dropped_groups`,
`client::tests::send_text_rejects_dropped_group`,
`client::tests::add_and_remove_members_reject_dropped_group`
(add/remove route through `resolve_send_group` so a recovered 0.8 id
commits on the live sibling, and a left chat cannot resume via admin),
`client::tests::pending_join_requests_see_folded_historical_sidecar`
(`pending_join_requests` / `active_invite_links` / decline / revoke
union the fold family so a pre-migration `sinvite1` token still
surfaces on the live group-info screen; `approve_join_request` commits
on `resolve_send_group`),
`client::tests::create_invite_link_after_fold_mints_on_live_sibling`
(a new token after resume embeds the live 0.9 id even when the host
still passes the recovered 0.8 id; minting does not call
`resolve_send_group` and must not create a group),
`client::tests::create_invite_link_rejects_unresumed_historical_group`
(an unresumed recovered room must not mint a token that names the dead
0.8 MLS id; send first to resume, then invite. Hosts map that error to
"Send a message first to resume this chat, then invite"),
`client::tests::create_invite_link_rejects_dropped_group`,
`client::tests::create_invite_link_marks_account_backup_dirty`
(minting a shareable secret enters the opportunistic backup window
without waiting for the next outbound send),
`client::tests::inbound_join_request_does_not_mark_account_backup_dirty`
(inbound joins stay relay-replayable and must not keep the account
permanently urgent),
`client::tests::push_token_share_from_recovered_08_peer_is_cached`
(`is_known_group_member` / `share_push_token_with_groups` walk recovered
0.8 members so a peer can share a wake token before either side resumes),
`client::tests::push_token_share_from_left_recovered_peer_is_rejected`,
`client::tests::resume_staged_media_rejects_dropped_group`,
`client::tests::resume_staged_media_on_recovered_chat_uses_resolve_send_group`
(in-flight media staged on a recovered 0.8 id goes through
`resolve_send_group` instead of encrypting against a dead MLS exporter),
`invite_link::tests::fold_family_unions_historical_invite_sidecar`,
`account_backup::tests::write_read_package_files_roundtrips_invite_sidecar`
(v2 backup packs `.sonar-invites.json` so nsec restore keeps minted
`sinvite1` secrets and pending join requests),
`persistence::wipe_removes_the_database` (wipe deletes every atomic
sidecar and its crashed `{suffix}.tmp`, including historical groups /
members / exporter secrets / folds / transcript / parked invites),
`media_staging::tests::wipe_removes_crashed_state_tmp`,
`push::tests::wipe_removes_crashed_cache_tmp`,
`account_backup::tests::wipe_backup_policy_removes_crashed_unique_tmp`,
`ConversationFoldTest.deleteAfterFoldDropsTheHiddenHistoricalSibling`
(`conversationsMatchFoldFamily` — Compose open-transcript refresh must
treat a remounted room and its hidden 0.8 sibling as the same chat,
matching iOS `snConversationsMatchFoldFamily`. `isSameDirectMarmotChat`
alone misses rooms after FFI hide),
`ConversationFoldTest.foldedHistoricalPaymentActivitiesMoveOntoLiveSibling`
(chat-scoped `SonarPaymentActivity.peerKey` remounts from the hidden 0.8
id onto the live sibling; wallet / Unify keys stay put. Hosts persist
the rewrite on fold promote and still read via the fold family so an
already-folded tester keeps the ⚡ count / transcript inject.
`SonarPaymentActivityLedgerTest.remountPeerKeysMovesHistoricalChatOntoLiveSibling`,
`SonarPayTests.testRemountPeerKeysMovesHistoricalChatOntoLiveSibling`,
`SonarConversationFoldTests` `snPaymentActivityPeerKeys` /
`snRemountedPaymentPeerKey`),
`ConversationFoldTest.foldedHistoricalPendingMediaUploadsMoveOntoLiveSibling`,
`SonarNotificationHandoffTest.notificationLiveFoldTargetsUsesPersistedBlobWhenFfiIsDown`,
`SonarNotificationHandoffTest.resolveOpenTargetRemapsFoldedHistoricalIdOntoLiveSibling`
(remap even when the live id is not in `knownChatIds`),
`marmot::historical_fold_tests::display_members_unions_folded_historical_roster`
(FFI paint unions leftover 0.8 members; `members(live)` stays single-id
so late-resume still invites them),
`marmot::historical_fold_tests::display_name_falls_back_to_folded_historical_title`
(FFI live `GroupInfo.name` keeps the recovered 0.8 title when MLS name
is blank; a later live rename wins. Compose `adoptedListedChatTitle`
must not replace a recovered name with "Group chat"),
`e2e.rs::recovered_08_group_adds_a_member_who_updates_later` and
`e2e.rs::recovered_08_group_adds_late_member_on_sync_without_a_local_send`
(after a mixed resume `members(live)==2` and `display_members` still
lists leftover Carol so late-resume and the remounted member sheet
cannot be collapsed into one helper),
`ConversationFoldTest.foldedHistoricalRoomRemountsOntoLiveSibling`
(open-transcript remount matches notification remap: a hidden 0.8 id
moves onto `live_fold_target` even before `chats()` lists the live
sibling; `notificationOpenChat` supplies the stub row. iOS
`snRemountFoldedOpenGroupId` is the same),
`listedOrFoldedSiblingChat` is bidirectional: unlisted live inherits
the still-listed 0.8 sibling; sitting on a hidden 0.8 id inherits the
listed live sibling. Compose `listedChat` (peer/call/send-duplicate /
group-info / contact-profile / open-chat chrome) uses that so a hidden
0.8 id still finds the live sibling — iOS `marmotGroup(byId:)` already
remaps via `snListedOrFoldedSiblingGroupId`. Open-transcript remount
also rewrites group-info / contact-profile / call nav ids
(`remountFoldedNavStack` / `snRemountFoldedPath`) so those screens do
not stay on a chat that `groups()` no longer lists.
`notificationOpenChat` uses that, else a not-direct
stub. `adoptedListedChatTitle` replaces a captured Compose
`Screen.Chat.name` of "Group chat" once `chats()` lists the remapped
row. iOS derives the title from `marmot.groups` / `marmot.title(for:)`
each render, so it does not have this captured-stub hole;
`snListedOrFoldedSiblingGroupId` is the iOS mirror),
`SonarConversationFoldTests` (`snNotificationLiveFoldTarget` remaps a
shade tap from the persisted blob when FFI is down),
`marmot::historical_fold_tests::recovered_08_media_decrypts_with_stored_exporter_secret`
(also pins decrypt via the remounted live id),
`SonarConversationFoldTests` (`snNotificationOpenGroupId` remaps a shade
tap onto the live sibling even before that id is listed),
`ConversationFoldTest.recoveredRoomWithOneKnownPeerDoesNotFoldOntoDirect`
(also pins `marmotChatDisplayTitle`: a named room with one listed peer
keeps the room name; the 1:1 profile path is `isDirect` only. iOS
`snMarmotChatDisplayTitle` / `MarmotChatModel.title(for:)` match),
`ConversationFoldTest.emptyTopicResumedRoomDoesNotFoldOntoWelcomerDm`
(in-memory `SonarChat` / `MarmotGroup` default is **not-direct**, matching
snapshot decode, so an omitted flag on an empty-topic 2-person room
cannot fold onto the welcomer 1:1; iOS
`MarmotProfileCacheTests.emptyTopicResumedRoomDoesNotFoldOntoWelcomerDm`),
`ConversationFoldTest.recoveredChatWaitsForPeerUpdateUntilLiveSiblingExists`
(`recoveredChatHasLiveFoldSibling` + `remountClearsRecoveredWaitingFlag`),
`SonarConversationFoldTests` (`snRecoveredChatHasLiveFoldSibling` +
`snRemountClearsRecoveredWaitingFlag`),
`ConversationFoldTest.deleteAfterFoldDropsTheHiddenHistoricalSibling`,
`SonarConversationFoldTests` (same asserts on `snFoldFamilyIds` /
`snPurgedHistoricalFolds` / `snPrunedOrphanedHistoricalFolds` /
`snMutedFoldKeys` — iOS gap-recovery and the central local-notification
gate walk the fold family so a mute stored on the 0.8 id still silences
a live 0.9 banner). A recovered room with no
live MLS group can still be deleted: Leave degrades to a local family purge. A pending welcome with
`member_count > 2` never uses `start_dm` even if only the welcomer is
known — that would fold the room onto a 1:1. `maybe_fold_new_group`
must still skip folding a recovered room onto a welcomer 1:1 (R-045).
Rooms fold onto a matching live non-DM (exact 3+ members, unique
subset, or named 2-person name+member match) on incoming welcome
and via `resolve_send_group`. Hosts still collapse a *person* by
npub (R-003 / R-045). Peer still on 0.8:
`KeyPackageNotFound` → "Waiting for them to update Sonar". After a later
successful resume, that banner must clear: FFI hide drops listed 1:1
duplicates back to 1 (rooms never have them), so the host treats a
persisted hist→live binding as the live sibling and remount **drops**
the waiting flag instead of copying it onto the working chat.

## Explicitly out of scope here

- Stage 2 multi-device (same nsec, several live devices) — #327
- Dual-stack 0.8+0.9 sender
- Importing 0.8 MLS secrets into a 0.9 session
- Accepting a stored 0.8 welcome *event* (0.8 wire) — pending rows are
  listed and can resume on a new 0.9 group, but the old welcome cannot
  be ingested
- Deleting `*.mdk08.bak` automatically
- Cold-start bench numbers on this machine (Debug + `SONAR_BENCH_NSEC`)

## Ship rule

Stay draft until:

1. The persistence / extract / fold tests above are green in CI.
2. The 0.9.14 group-scale table is committed.
3. Device upgrade + White Noise interop still need a human pass
   (cannot be substituted by unit tests).

## Local gates last verified

Re-run on `0486044e` after concurrent-resume fold pin.

| Gate | Result |
| --- | --- |
| `--lib` `--` `mdk08_migrate` `historical_fold` `account_backup` `client::tests` | 201 passed on `d5e2a5b6` |
| `--lib` `--` `incoming_09_` | 9 passed on `0486044e` |
| `--lib` `--` `historical_fold` `copy_summary` | 14 passed on `0486044e` (`historical_fold` 12) |
| `--test persistence` | 30 passed on `d5e2a5b6` |
| `--test group_invites` | 17 passed earlier on this branch |
| `--test failed_events` | 1 passed earlier on this branch |
| `--test media` | 4 passed earlier on this branch |
| `-p sonar-sim` | 5 passed earlier on this branch |
| `--test e2e` `recovered_08` | 7 passed on `d5e2a5b6` |
| Compose `SonarNotificationHandoffTest` + `ConversationFoldTest` | passed earlier on this branch |

Joined-room hole closed after `900f9788`: a recovered named 0.8 room with
only one known peer no longer resumes as `start_dm`. Extract copies
`groups.description` and processed-welcome `member_count`;
`historical_resume_is_direct` matches live `group_is_direct`. Early
`metadata_backfill=complete` markers re-run as `v2` so already-quarantined
baks pick up the new sidecars.

Incoming mixed-room hole closed after this commit: exact member match
missed the `resolve_send_group` shape (live others are whoever already
published a 0.9 KeyPackage). Fold a recovered 3+ room when the live
others are a **unique subset** of that roster; if two recovered rooms
overlap with no unique name, skip. Pins:
`incoming_09_room_welcome_folds_when_live_is_subset_of_recovered`,
`incoming_09_room_welcome_skips_ambiguous_overlapping_rooms`.

Incoming 0.9 room welcome hole closed after this commit: `maybe_fold`
used to skip every recovered room (only `resolve_send_group` folded
them). A peer who recreated the same 3+ room left a split: new empty
0.9 row + recovered 0.8 history. Fold when both sides are non-DM, both
have 3+ members, and the other-member sets match. A recovered room
still must not fold onto a welcomer 1:1 (R-045). Pins:
`incoming_09_room_welcome_folds_recovered_08_room`,
`incoming_09_dm_welcome_does_not_fold_recovered_room`.

Incoming named-pair hole closed after this commit: a recovered 0.8
named 2-person room (or White Noise DM without `sonar.direct-dm.v1`)
classifies as a room, and incoming `create_group("standup", [peer])`
auto-joins. Folding only 3+ rooms left that history as a second row.
Fold on unique name + exact member match only. Name mismatch and a
3-person recovered standup with the same title stay unfolder. Pins:
`incoming_09_named_pair_welcome_folds_recovered_named_room`,
`incoming_09_named_pair_welcome_skips_when_names_differ`,
`incoming_09_named_pair_welcome_does_not_fold_three_member_room`.

Concurrent-resume hole closed after this commit: `historical_groups()`
still lists a folded 0.8 row, so a second matching 0.9 welcome
overwrote `historical_folds` and `messages()` moved 0.8 history onto
the empty new MLS group. Skip already-folded hist. The second live
group can still appear (two MLS graphs cannot merge); history stays
on the first resume. Pin:
`incoming_09_named_pair_second_welcome_does_not_steal_fold`.

Incoming 0.9 DM welcome hole closed after this commit: 1:1 welcomes
auto-join as `Incoming::GroupUpdated` and parked 2-member Accept uses
`accept_group_invite`. Neither path called `maybe_fold_new_group` (only
local `publish_group_creation` did), so a peer who already updated
could start a new 0.9 DM and leave the recovered 0.8 row listed. Hosts
dedupe 1:1s by npub while both ids are listed, but a send on the 0.8 id
then minted a *second* 0.9 group. Recovered rooms still must not
fold onto a welcomer 1:1 (R-045). Pins:
`client::tests::incoming_09_dm_welcome_folds_recovered_08_direct_chat`.

Incoming-DM unread hole closed after this commit: `copy_summary` used to
keep live unread when the live 0.9 row already had a badge
(`CASE WHEN unread_count = 0 THEN excluded ELSE unread_count`). Local-send
resume (live unread 0) copied recovered unread; incoming `maybe_fold_new_group`
did not. Hosts place the unread divider by walking `unread_count` visible
incoming rows, and `conversation_summaries()` hides the historical sibling,
so recovered missed messages lost their divider. Pins:
`conversation_index::copy_summary_adds_historical_unread_onto_live_that_already_has_unread`.

Compose room-banner hole closed after this commit: `maybeNotify`
scanned and suppressed only the listed live id. iOS already treats
fold-family ids as the same conversation (`snConversationsMatchFoldFamily`).
Sitting in the recovered 0.8 transcript when the 0.9 sibling landed
could ring the live banner. Suppress the fold family; keep scan on
listed ids so a bak remainder cannot replay recovered history.
Pin: `ConversationFoldTest.notificationSuppressIdsIncludeHiddenHistoricalSibling`.

Viewing-unread hole closed after this commit: Compose
`transcriptGroupIds` for a non-mesh room was only
`directMarmotChatIds` (the listed live id). iOS
`syncViewingUnreadGroups` only walked `directMarmotGroups` (1:1
duplicates). Sitting in a remounted room — or in the recovered 0.8
transcript before remount — left the hidden sibling's unread on the
home-list badge. `transcriptSourceIds` / `snTranscriptSourceIds`
union the listed ids with the fold family for viewing suppress,
mark-read, and unread-at-open. FFI `messages()` already unions the
family, so iOS transcript hydration still pages listed groups only.
Pins: `ConversationFoldTest.transcriptSourceIdsIncludeHiddenHistoricalSibling`,
`SonarConversationFoldTests` `snTranscriptSourceIds`.

iOS remainder-refresh hole closed after this commit: `conversationChanged`
can name the hidden 0.8 id (`notify_fold_aliases` / bak remainder).
Compose already remaps via `conversationsMatchFoldFamily` and reloads
the open live page. iOS `scheduleConversationRefresh` treated an
unlisted hist id as a brand-new group (`loadLocalSummaries`) and left
the remounted live window stale. `snConversationRefreshIds` reloads
listed fold siblings. Pin: `SonarConversationFoldTests`
`snConversationRefreshIds`.

In-flight media hole closed after this commit: pending uploads remounted
only while the recovered transcript was open. Fold after the user left
left bytes keyed on the hidden 0.8 id. Promote uploads (and Compose
pending-group queues) on the same refresh path as send echoes. iOS
upload-cache remount merges colliding live keys instead of overwriting.
Pins: `ConversationFoldTest.foldedHistoricalPendingMediaUploadsMoveOntoLiveSibling`,
`SonarConversationFoldTests` `snRemountedPendingUploadMediaKey`.

Compose remount catch-up hole closed after this commit: opening the
recovered 0.8 id called `preferCatchupGroup` on a group FFI no longer
lists. iOS remount already `refreshWhenConnected` the live sibling.
Remount now catch-up-prioritizes the live 0.9 id. Trill cooldown
promotion no longer returns early when there are no in-flight echoes.

iOS Leave/delete hole closed after this commit: standard defaults
dropped the hist→live blob but the App Group mute mirror did not.
NSE could keep treating a deleted recovered room as folded. Compose
already persists the purged blob (`forgetHistoricalFolds`).
`snPersistHistoricalFolds` writes both stores.

In-flight send-closure hole closed after this commit: promote
moved pending media / drafts onto the live sibling, but hist-keyed
send / retry / merge and `composerDraft(live)` still looked only at
the hidden 0.8 id. Notification remaps onto live before promote, so a
typed draft or in-flight photo disappeared. Lookups now walk the fold
family; `conversationChangeTargetId` / `snConversationChangeTargetId`
stage remainder ticks on the listed live id. Pins:
`ConversationFoldTest.pendingMediaUploadLookupWalksFoldFamily`,
`ConversationFoldTest.composerDraftReadAndClearWalkFoldFamily`,
`ConversationFoldTest.conversationChangeTargetPrefersListedLiveSibling`,
`ConversationFoldTest.conversationChangeRefreshesOpenMeshFromHiddenSibling`,
`SonarConversationFoldTests` `snPendingUploadLookupGroupIds` /
`snComposerDraft` / `snConversationChangeTargetId` /
`snConversationChangeShouldRefreshOpenMesh`.

Mesh remainder-tick hole closed after this commit: Compose
`handleConversationChange` resolved `peerIdForMarmotGroup(hist)`
only. Persist-folds prune `groupFoldMap[hist]`, so sitting in
`mesh:<peer>` missed bak remainder until the 30s heartbeat.
`conversationChangeShouldRefreshOpenMesh` walks the fold family
and resolves the peer from the listed live sibling. iOS remainder
refresh already pages the family via `snConversationRefreshIds`.

Leave-paint hole closed after this commit: Compose remounted
`retainedTranscriptByChat` only while the recovered transcript was
open. Fold after Leave left the last painted window keyed on the
hidden 0.8 id, so tapping the live 0.9 row awaited FFI before first
paint. Promote retained + transcript windows on the same refresh
path as send echoes; `openChat` / `firstOpenTranscriptPaint` walk
the fold family. iOS already promoted `messagesByGroup`; it now also
remounts closed `ConversationViewState` windows and
`dmHasLocalTranscriptPaint` walks the family. Pins:
`ConversationFoldTest.retainedTranscriptReadWalksFoldFamily`,
`SonarConversationFoldTests` `snRetainedTranscriptForChat`.

Quote-jump after Leave is not a remount hole: both hosts clear the
jump on pop (`back()` / `pop()`). In-chat quote while fold lands is
already remounted with the open chat.

Mesh-banner hole closed after this commit: Compose `maybeNotify` for a
White Noise group folded into a mesh row suppressed only `[live, mesh]`.
Sitting in the recovered 0.8 transcript rang the mesh identity. Scan
stays on the listed live id; suppress now walks the fold family.
iOS already matches fold family via `conversationsMatchForNotification`.
Pins: `ConversationFoldTest.notificationSuppressIdsIncludeHiddenHistoricalSibling`
(mesh case), `SonarConversationFoldTests` `snMeshNotificationSuppressIds`.

Load-older hole closed after this commit: iOS remounted `messagesByGroup`
after fold but left `hasOlder` / load-older cursors on the hidden 0.8 id.
Fold after Leave, then reopen the live row offline, could not page bak
remainder. Promote paging flags/cursors on the same `groups()` path as
the transcript cache; remount ORs `hasOlder`. Compose already ORs
`transcriptWindows.hasMore` and now pins `foldedSiblingHasMore`.
Pins: `ConversationFoldTest.foldedSiblingHasMoreKeepsLoadOlderAfterLeave`,
`SonarConversationFoldTests` `snPromotedFoldedPagingFlags` /
`snPromotedFoldedPagingCursors`.

Restore host-fold hole closed after this commit: nsec restore correctly
wipes the *previous* account's `sonar.historicalFolds` blob, then
persisted empty until the next `groups()` / `refreshChats` remember.
Family walks (mute remap, notification-tap fallback, NSE App Group,
composer/retained, scan-watermark prune) missed the restored sidecar
for one cycle. Rediscover from listed live ids via `fold_aliases`
*before* first paint / promote; prune scan keys with the fold family.
Pins: `ConversationFoldTest.accountRestoreHostFoldsComeFromLiveSiblingNotPreviousAccount`,
`ConversationFoldTest.retainedScanChatIdsKeepHiddenHistoricalSibling`,
`SonarConversationFoldTests` `snHistoricalFoldsAfterAccountRestore` /
`snRetainedScanChatIds`.

Home-row unread hole closed after this commit: open-path
`transcriptSourceIds` already walked the fold family (viewing suppress,
mark-read, unread-at-open), but the home badge did not. Compose
`computeMarmotRowModels` / `unreadForChat` summed listed ids only
(rooms = live id); iOS room rows keyed `unreadByGroup[group.id]` and
`hasUnreadMarmotMessage` walked listed 1:1 duplicates. After collapse,
`unreadByChat[hist]` still held the badge until summaries remounted
onto live — the visible row looked read. `unreadForFoldFamily` /
`snUnreadForFoldFamily` reuse the transcript-source set. Pins:
`ConversationFoldTest.homeRowUnreadFollowsPersistedFoldOntoLiveSibling`,
`SonarConversationFoldTests` `snUnreadForFoldFamily`.

Mark-read follow-up: `openChat` still passed only `directMarmotChatIds`
(rooms = live id) into `markGroupsRead`, unlike `openDm`. After the
home-row walk, leftover `unreadByChat[hist]` re-badged the live row
until summaries refreshed. `markGroupsRead` now expands the fold
family on the host map (core already did); `openChat` /
`refreshOpenDm` use `transcriptGroupIds`. iOS `markConversationRead`
clears the same family keys.

Shade-clear hole: Compose `clearNotificationsForChat` walked listed
transcript ids but not their hidden 0.8 siblings (mesh rows especially).
iOS `clearNotificationsForConversation` walked listed 1:1 duplicates
only. A pre-fold banner keyed on hist stayed in the shade after the
live row opened. `notificationClearIds` / `snNotificationClearIds`
expand the fold family (and `marmot:` aliases on iOS). Mute lookup
walks family of transcript ids the same way.

Verified-row hole: promote already copies a 0.8 safety-number flag onto
live, but `isVerified` / home-row checkmarks still keyed listed ids
only. After collapse the hist key stayed in `verifiedChatIds` while the
visible 0.9 DM looked unverified until remount. `verifiedForFoldFamily`
/ `snVerifiedForFoldFamily` reuse the transcript-source set.

Hydrate-preview hole: after collapse, Compose `hydrateLocalConversationRows`
and iOS `conversationSummariesByGroup` kept only `groups()` / `activeChatIds`.
A leftover hist-keyed conversation-index row was dropped, so the live home
row stayed on "Tap to open" even when recovered last-message text was still
in the index (window before `copy_summary`, or persist-folds collapse
before core fold). `hydrationTargetId` / `snHydrationTargetGroupId`
remount leftover hist summaries (and Compose pages) onto the live sibling.
Pins: `HomeMessageRowsTest.foldedHistoricalSummaryHydratesOntoLiveSibling`,
`SonarConversationFoldTests` `snHydrationTargetGroupId` /
`snRemountedConversationSummaries`.

iOS page / groups hole: Compose collapses FFI chats on every refresh and
remounts leftover hist pages onto live. iOS only collapsed the cold-start
snapshot, then `loadLocalSummaries` published raw `groups()` and keyed
pages on `page.groupId`. Persist-folds before core fold could show a dual
home row, leave recovered messages on the hidden id, and let
`loadLocalPage(.newestPage)` replace the live window with an empty/new
0.9 page. `publishedGroups` collapses every FFI assign; pages remount via
the hydration target; `snFoldFamilyCachedMessages` seeds open/home from
the hidden sibling. Pins:
`HomeMessageRowsTest.foldedHistoricalPageHydratesOntoLiveSibling`,
`SonarConversationFoldTests` `snFoldFamilyCachedMessages`.

Call-log hole closed after this commit: payment reads already walked the
fold family (`paymentActivityPeerKeys` / `snPaymentActivityPeerKeys`), but
`callRecords` / `mergeCallLogs` keyed only the open id. After collapse,
persisted 0.8 call rows stayed on the hist key until async promote — first
paint of the live transcript dropped recovered CallLog rows. `callRecordsForChat`
/ `snCallLogsForChat` reuse the payment key set (bare + `marmot:` on iOS)
and last-wins on the live id. Pins:
`ConversationFoldTest.callRecordsReadWalksFoldFamily`,
`SonarConversationFoldTests` `snCallLogsForChat`.

Pending-echo hole closed after this commit: `withSendEchoes` / `dmMsgs`
keyed only the open id (plus listed 1:1 duplicates). A failed or in-flight
send left on the hidden 0.8 id vanished from the live transcript until
async promote. `pendingMessagesForChat` / `snPendingMessageKeys` reuse the
same fold-family key set as payments and call logs. Compose clear / fail /
accept / terminal-accepted cleanup also walk the family so a hist-keyed
echo cannot stay "Sending" on the live row. Pins:
`ConversationFoldTest.pendingMessagesReadWalksFoldFamily`,
`ConversationFoldTest.pendingMessagesMutateWalksFoldFamily`,
`SonarConversationFoldTests` `snPendingMessageKeys`.

Open-target hole closed after this commit: iOS `marmotGroupId` and
Compose `resolveMarmotGroupId` returned a persisted / prefix-stripped
hist id even after FFI listed only the live sibling. `preferCatchupGroup`
looks up `engine.groups()` (live MLS only), so a stale mesh mapping
cleared catch-up instead of kicking the 0.9 group. `resolvedOpenGroupId`
/ `snResolvedOpenGroupId` remap onto the listed sibling. Pins:
`ConversationFoldTest.resolvedOpenGroupIdRemapsStaleHistOntoListedLive`,
`SonarConversationFoldTests` `snResolvedOpenGroupId`.

Transcript-cache hole closed after this commit: iOS `dmMsgs` and Compose
snapshot paint keyed only the open / listed id. Home already walked
`snFoldFamilyCachedMessages` / remounted pages, but the live transcript
first frame could miss leftover 0.8 rows until async remount or FFI
family union. `dmMsgs` and `snapshotMessagesForChat` now union the host
cache (sorted before the page suffix). Background notify scan stays
listed-id only so a bak remainder cannot replay. Pins:
`ConversationFoldTest.foldFamilyCachedMessagesUnionsHiddenSibling`,
`SonarConversationFoldTests` `snFoldFamilyCachedMessages`.

Load-older hole closed after this commit: `hasOlderLocalMessages` /
`transcriptWindows.hasMore` keyed only the live id. After collapse the
0.8 page still had remainder (`*.mdk08.bak` / older local rows) while
the live flag was false, so first paint of recovered history could not
scroll up. `snFoldFamilyHasOlder` / `hasOlderForFoldFamily` OR the
family flags; load-older on live uses the hist cursor when the live
row has none. Untrusted Compose snapshot fallback no longer pins
`hasMore=false`. Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`,
`SonarConversationFoldTests` `snFoldFamilyHasOlder` /
`snFoldFamilyPagingCursor`.

iOS trill cooldown hole closed after this commit: Compose
`trillCooldownUntilMsForChat` already walked the fold family; iOS
`canSendTrill` keyed only `chatAlertKey(id)`. After collapse a nudge
sent on the hidden 0.8 id did not disable the live row until async
promote. `snTrillCooldownUntil` reuses the payment key set. Pins:
`ConversationFoldTest.trillCooldownReadsHiddenHistoricalSibling`,
`SonarConversationFoldTests` `snTrillCooldownUntil`.

Family-cache overflow hole closed after this commit: Compose first
paint `takeLast(page)` of a family-unioned host cache dropped older
recovered 0.8 rows while both `hasMore` flags stayed false, and
`beginTranscriptSession` cleared the source window so load-older
could not prepend them. iOS already compared render vs `dmMsgs`
candidates (`hasRowsOlder`). `seededFoldFamilyTranscriptHasMore` /
`snSeededFoldFamilyTranscriptHasMore` treat union count > page as
has-older; open / newest-reload seed the full family cache (capped
at the retained window) before bounding paint. Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`,
`SonarConversationFoldTests` `snSeededFoldFamilyTranscriptHasMore`.

Retained-reopen hole closed after this commit: Compose
`firstOpenTranscriptPaintRows` preferred a non-empty live leave-frame
over the remounted family snapshot, and the retained `openChat` path
skipped window seed. Reopening a short 0.9 leave-paint hid recovered
0.8 rows until FFI (and persist-folds-before-core-fold never brought
them back). Leave-paint now unions snapshot extras; retained reopen
seeds the family window like first open. iOS `rebuildNow` already
unions via `dmMsgs`. Pins:
`ConversationFoldTest.retainedTranscriptReadWalksFoldFamily`,
`SonarConversationFoldTests` `snFirstOpenTranscriptPaintRows`.

First-open FFI hole closed after this commit: with no leave-paint,
`openChat` / `openDm` waited on `messagesCursorPage(live)` without
seeding the remounted family snapshot. A live-only page (persist-folds
before core fold) replaced recovered 0.8 rows. First-open now seeds
`firstOpenFoldFamilySeedRows` into the source window so the local
merge keeps them; still waits for the cursor before push (no
snapshot→async flash). iOS `loadLocalPage` already merges
`hiddenSiblingHasRows`. Pins:
`ConversationFoldTest.firstOpenFoldFamilySeedSurvivesLiveOnlyLocalPage`.

Quote-jump key hole closed after this commit: iOS
`applyQuotedMessageRevealIfNeeded` and the DM/Mac hosts keyed
`jumpMessageIdAtOpenByDM[conversationId]` / `[peerId]` only. A quote
tap after remount copied maps but before nav rewrote the route wrote
hist; the live `ConversationViewState` never expanded. Compose remount
moved the jump off hist, so a stale `screen.id` lookup missed. Read /
write / clear / capture now walk the fold family (`quotedJumpParentId`
/ `snQuotedJumpParentId`, including `marmot:` on iOS). Pins:
`ConversationFoldTest.quotedMessageRevealExpandsPaintedPageToParent`,
`SonarConversationFoldTests` `snQuotedJumpParentId`.

First-open gate hole closed after this commit: Compose `openChat` /
`openDm` only immediate-pushed a retained leave-frame, so a remounted
0.8 snapshot still waited on `messages(live)` before Chat mounted.
iOS `dmHasLocalTranscriptPaint` checked listed `messagesByGroup[live]`
only, so `openDM` waited on `loadLocalWhenConnected` while recovered
rows sat on the hidden sibling. Immediate paint now uses
`firstOpenHasLocalTranscriptPaint` / `snDMHasLocalMarmotPaint`. Pins:
`ConversationFoldTest.retainedTranscriptReadWalksFoldFamily`,
`SonarConversationFoldTests` `snFirstOpenHasLocalTranscriptPaint` /
`snDMHasLocalMarmotPaint`.

Load-older overwrite hole closed after this commit: after newest-page
armed `hasOlder` from the remounted 80-row extract, the first cursor
page can be empty/short (bak remainder not copied yet). Both hosts
wrote `hasOlder = rawPage.count > pageSize`, which disarmed the family
and left remainder unreachable. `loadOlderPageHasOlder` /
`snLoadOlderPageHasOlder` keep the previous arm unless the short page
admitted new rows. Compose load-older also reuses a sibling cursor
when the hist window is empty (`foldFamilyPagingCursor`). Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`,
`SonarConversationFoldTests` `snLoadOlderPageHasOlder`.

Mesh-folded paging hole closed after this commit: Compose
`transcriptGroupIds` / `marmotMessagesForPeer` for a `mesh:` row returned
listed live groups only. After persist-folds the 0.8 sibling is hidden
from `groups()`, so openDm hydrate and load-older never queried hist.
`meshFoldTranscriptSourceIds` / `snMeshFoldTranscriptSourceIds` expand
those live / resolved ids through the fold family (iOS
`localTranscriptGroups` uses the same helper). Pins:
`ConversationFoldTest.transcriptSourceIdsIncludeHiddenHistoricalSibling`,
`SonarConversationFoldTests` `snMeshFoldTranscriptSourceIds`.

iOS openDM hydrate hole closed after this commit: extra newest-page
and `needsHistoryBackfill` used listed 1:1 groups only. After
persist-folds live is empty while recovered rows sit on hist, so first
open waited on relay and never newest-paged bak remainder. Extra hydrate
now pages `localTranscriptGroups`; backfill waits only when the fold
family cache is empty (`snFamilyTranscriptNeedsNetworkBackfill` /
`familyTranscriptNeedsNetworkBackfill`). Pins:
`ConversationFoldTest.transcriptSourceIdsIncludeHiddenHistoricalSibling`,
`SonarConversationFoldTests` `snFamilyTranscriptNeedsNetworkBackfill`.

iOS snap-to-newest hasOlder hole closed after this commit: after
paging remounted 0.8 rows the older-edge pin is set; scrolling back
to the bottom replaces the window with a short live 0.9 page and
wrote `hasOlder = rawPage.count > page`. Remainder was unreachable.
The replace path now uses `snNewestPageFamilyHasOlder` (existing
family count + hidden-sibling/previous arm). Compose
`refreshTranscriptGroupWindow` already did. Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`,
`SonarConversationFoldTests` `snNewestPageFamilyHasOlder`.

Recovered-media fetch hole closed after this commit: Compose
`fetchMediaToFile` used `resolveMarmotGroupId` (live) and iOS stamped
`SNMediaItem.groupId` with the painted source. Persist-folds can land
before core `fold_family`, so a live-only fetch misses hist exporter
secrets. Both hosts now try `mediaFetchGroupIds` /
`snMediaFetchGroupIds`. Pins:
`ConversationFoldTest.transcriptSourceIdsIncludeHiddenHistoricalSibling`,
`SonarConversationFoldTests` `snMediaFetchGroupIds`.

iOS remounted-extract source-limit hole closed after this commit:
`dmMsgs` formats only `sourceMessageLimit` (30) Marmot rows. After
persist-folds the 80-row first-paint extract is already in the family
cache; load-older that re-reads that page reports `added=false` and
never grew the source window, so the rest of the extract — and bak
when bak is empty — stayed unreachable. `rebuildNow` now raises
`sourceMessageLimit` with `snCachedFoldFamilySourceLimit`. Compose
`transcriptWindows` already hold the full extract. Pins:
`ConversationFoldTest` `cachedFoldFamilySourceLimit`,
`SonarConversationFoldTests` `snCachedFoldFamilySourceLimit`.

Compose quote-jump miss hole closed after this commit: after a
load-older miss (`!added`) `App.kt` cleared the jump. An empty first
bak page / persist-folds hist miss is not exhaustion, so recovered 0.8
quote and notification jumps were dropped before remainder could
admit the parent. Clear only through `shouldClearQuotedJumpAfterMiss`
(`shouldSettleQuotedJump`). iOS `applyQuotedJump` already kept the
target. Pins: `ConversationFoldTest` `shouldClearQuotedJumpAfterMiss`,
`SonarConversationFoldTests` `snShouldClearQuotedJumpAfterMiss`.

Short live-page hasOlder hole closed after this commit: home hydrate
only remounts 20 rows (`LOCAL_SUMMARY_PAGE_LIMIT`). After persist-folds
the live 0.9 newest page is short, so `existing+incoming` stays ≤30 and
`newestPageFamilyHasOlder` disarmed load-older while extract 21–80 and
bak remained on hist. A short incoming page now keeps the flag when a
fold family remount already exists. Pins: `ConversationFoldTest`
`newestPageFamilyHasOlder` `hasFoldFamily`, `SonarConversationFoldTests`
`snNewestPageFamilyHasOlder`.

iOS remainder-tick refresh hole closed after this commit: a bak tick
names hist; `snConversationRefreshIds` remapped to listed live only.
Persist-folds `messages(live)` does not union hist, so the open
transcript never grew and a kept quote-jump could not retry. Refresh
now pages the hidden sibling too (`snConversationRefreshShouldLoadPage`
even when unlisted / uncached). Compose `marmotMessagesPageForChat`
already pages the family; helpers stay in lockstep. Pins:
`ConversationFoldTest` `conversationRefreshIds`,
`SonarConversationFoldTests` `snConversationRefreshIds`.

Compose home-hydrate wipe hole closed after this commit: persist-folds
remount the leftover 0.8 extract onto live, then
`hydrateLocalConversationRows` replaced it. A newer live summary used
`lastOrNull()` (oldest on a newest-first extract) and wrote one
`summary:` stand-in; chats outside the home page window never got the
rows back. A newer live page then replaced the remounted extract
entirely. Keep real rows (`hydrationHasRealTranscriptRows`) and merge
pages (`hydrateMergedPageRows`). iOS already merges in
`loadLocalSummaries` and never writes synthetics into
`messagesByGroup` (home paint is `snMarmotHomeRowMessage` only). Pins:
`HomeMessageRowsTest.remountedExtractSurvivesNewerSummaryOutsidePageWindow`,
`HomeMessageRowsTest.remountedExtractMergesNewerLivePageInsteadOfReplacing`,
`SonarConversationFoldTests` `snHydrateMergedPageRows`.

Core persist-folds media hole closed after this commit: a live-id
`decrypt_media_by_url` / `recovered_08_media_unavailable` only searched
`transcript_for_family`. Host sidecar can remount the bubble onto live
before `record_historical_fold`, so a live-only fetch missed hist
imeta and exporter secrets. Look the blob up by blossom URL across
historical transcripts — do not invent a fold (R-045). Hosts still
retry `mediaFetchGroupIds`. Pins:
`persist_folds_live_id_decrypts_recovered_08_media_without_core_fold`,
`persist_folds_live_id_marks_recovered_08_media_unavailable_without_secret`,
`persist_folds_live_id_fetch_media_uses_hist_exporter_without_core_fold`.

Newest-first remount recency hole closed after this commit:
`localLatestTsForChat` used `lastOrNull()` on an unsorted fold merge.
A remounted 0.8 extract then looked older than a newer empty live
sibling, so `dedupeDirectMarmotChats` hid the row that still held
recovered history. Take `max(tsSecs)` and `latestByChat`. iOS
`snLocalLatestTsForChat` / `latestMarmotMessage` stay in lockstep.
Pins: `ConversationFoldTest.snapshotLatestFollowsPersistedFoldOntoLiveSibling`,
`SonarConversationFoldTests` `snLocalLatestTsForChat`.

Compose already-open mesh-folded remount hole closed after this commit:
`pageHiddenFoldFamilyForOpenLiveChat` returned on `isMeshChat`. A
`mesh:<peer>` route is not a fold-family key and cannot be handed to
`marmotMessagesPageForChat`. Sitting in that DM while persist-folds
landed skipped hist, so an empty mesh+0.9 paint stayed on “Say hi”.
Gate on `transcriptGroupIds` / `meshFoldTranscriptSourceIds` and page
through `localTranscriptRowsForChat` (iOS `marmotGroupId` then
`pageUnpagedHiddenFoldFamily`). Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`
(`shouldPageHiddenFoldFamilyForOpenLive` mesh family ids).

Compose already-open live remount hole closed after this commit:
`remountFoldedOpenChat` only swapped nav when the open id was hist.
Sitting on an empty listed 0.9 room skipped the hidden sibling page,
so the UI stayed on “Say hi” until the 30s heartbeat.
`pageHiddenFoldFamilyForOpenLiveChat` newest-pages hist (iOS
`pageUnpagedHiddenFoldFamily`); empty load-older publishes the family
window instead of bailing. Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`
(`shouldPageHiddenFoldFamilyForOpenLive`,
`loadOlderEmptyPaintShouldPublishFamily`).

Persist-folds already-open live load-older hole closed after this commit:
host remounts hist onto an already-open live transcript without
re-running `openedDM`. Home hydrate then drops the hist cache key and
leaves `hasOlder` false, so extract 21–80 and bak stayed in the DB.
`hiddenFoldFamilyNeedsPage` arms load-older until hist has a paging
key; `loadOlderLocalPage` newest-pages that sibling (Compose
`refreshTranscriptGroupWindow`). Do not invent a fold (R-045). Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`,
`SonarConversationFoldTests` `snHiddenFoldFamilyNeedsPage`.

Persist-folds quote-preview hole closed after this commit:
`hydrate_page_reply_previews` only looked at parents on the same FFI
page. A live reply to a hist parent left an empty chip. Look the
parent up across stored transcripts (`lookup_chat`) — do not invent a
fold (R-045). Compose `quotedParentInFamilyCache` matches iOS
`snReplyRef(parents:)`. Pins:
`persist_folds_live_page_hydrates_reply_preview_from_hist_parent`,
`ConversationFoldTest.quotedMessageRevealExpandsPaintedPageToParent`,
`SonarConversationFoldTests` `snQuotedParentInFamilyCache`.

Process-death snapshot recency hole closed after this commit:
`encodeChatSnapshot` preferred `lastOrNull()` over `latestByChat`.
A newest-first remount persisted the oldest extract row as durable
latest. After process death the in-memory extract is gone, so
`localLatestTsForChat` read that oldest stamp and hid the recovered
row again. Persist `max(message ts, latestByChat)`. iOS snapshot is
groups-only; `snChatSnapshotLatestTs` is the persist contract.
Pins: `ConversationFoldTest.snapshotLatestFollowsPersistedFoldOntoLiveSibling`,
`SonarConversationFoldTests` `snChatSnapshotLatestTs`.

Compose load-older paged-keys hole closed after this commit: seed
copied the remounted extract onto hist `transcriptWindows` before
any FFI page. Passing those keys as “paged” made
`hiddenFoldFamilyNeedsPage` false and load-older skip hist, so bak
remainder stayed in the DB until the 30s heartbeat. Trusted FFI
page ids (`freshCanonicalByGroup`) match iOS cursor ∪ hasOlder.
`loadOlderHiddenSiblingsNeedingNewestPage` newest-pages hist first.
Pins: `ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`,
`SonarConversationFoldTests` `snPagedFoldFamilyGroupIds` /
`snLoadOlderHiddenSiblingsNeedingNewestPage`.

iOS blank-recovery latestAt hole closed after this commit: `copy_summary`
leaves live `message_count` at 0 on conflict. iOS
`snBlankTranscriptKnownNonEmpty` used count only, so persist-folds
skipped recovery while bak remainder sat on hist. Compose already
used latest-or-count. iOS now matches. Pins:
`SonarConversationFoldTests` `snBlankTranscriptKnownNonEmpty` latestAt,
`ConversationFoldTest` `blankTranscriptKnownNonEmpty` latestByChat.

iOS home-row latestAt hole closed after this commit: the same
`copy_summary` zero-count left `snMarmotHomeRowMessage` returning nil
when process death cleared `messagesByGroup`. Preview became the
generic placeholder and `lastDate` sorted as distantPast, burying the
recovered row. Compose hydrate already mints a synthetic from
`latestAtSecs > 0`. iOS home paint now matches. Pins:
`SonarConversationFoldTests` `snMarmotHomeRowMessage` zero-count latestAt,
`SonarConversationRegressionSmokeTests.copySummaryZeroCountStillPaintsHomeRowFromLatestAt`,
`HomeMessageRowsTest.copySummaryZeroCountStillHydratesPreviewFromLatestAt`.

iOS load-older family-cursor hole closed after this commit: after
newest-paging hist, `loadOlderLocalPage` borrowed the hist cursor onto
`messagesCursorPage(live)`. Persist-folds live FFI has no hist rows, so
extract 32–80 and bak stayed stuck. Page each sibling that still has
remainder with that sibling's own cursor (Compose
`loadOlderMessages` already does). Pins:
`ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`
(`loadOlderFamilyPageIds`),
`SonarConversationFoldTests` `snLoadOlderFamilyPageIds`.

iOS load-older hist-as-open-id hole closed after this commit:
`loadOlderDM` pages `localTranscriptGroups` including hist.
`loadOlderLocalPage(hist)` then treated live as an unpaged hidden
sibling and newest-paged the remounted extract (snap). Skip newest-page
when the sibling already has cached rows. `loadOlderDM` compares
family-union ids so a hist older-page counts as `added` and rebuilds.
Pins: `ConversationFoldTest.hasOlderForFoldFamilyReadsHiddenSibling`
(`foldFamilyCanonicalMessageIds` / live extract not newest-paged),
`SonarConversationFoldTests` `snFoldFamilyCanonicalMessageIDs`.

Lost-core-sidecar mixed-resume hole closed after this commit: a 2-person
live room from a partial 0.8 resume (`alice+bob`, leftover carol) only
got `record_historical_fold` at mint time. Host persist-folds can keep
that remount after the core sidecar is gone; `maybe_fold_new_group`
skipped `live_count < 3` (R-045 guard for DMs). Idle
`ensure_subscriptions` and a later send on the listed live id now
rebuild that bind only when the live room still carries the recovered
non-empty 0.8 topic (name + description). An incoming 2-person
`create_group("standup")` (empty desc) must not absorb a recovered
3-person standup. Pins:
`persist_folds_lost_core_sidecar_refolds_mixed_resume_on_ensure_subscriptions`,
`incoming_09_named_pair_welcome_does_not_fold_three_member_room`,
`recovered_08_pending_room_send_creates_named_group_not_dm`
(`ensure_subscriptions` after `start_dm`).

Empty-description 0.8 rooms cannot use that topic-match heal. At mint,
`promote_index_fold` now also writes the hist→live pair into the
conversation-index SQLCipher file (schema v3 `historical_fold`).
`connect` / `ensure_subscriptions` restore recorded pairs when the JSON
sidecar is gone. Do not infer an empty-desc bind from founder/admin or
unique subset (R-045). Restore also runs on `groups()`,
`conversation_summaries`, `messages` / page / cursor,
`display_members` / `display_name`, `live_fold_target_hex` /
`fold_aliases_hex`, `leave_group` / `delete_group`,
`maybe_fold_new_group`, `resolve_send_group` (hist mint path),
`invite_family` / `invite_mint_group`, `group_is_direct` (a 2-person
live sibling of an empty-topic room must not paint as a DM), and a
successful `store_join_request` notifies every family id so live
group-info wakes. Do not restore inside `is_folded_historical_group`
itself.
Pins:
`persist_folds_lost_core_sidecar_refolds_empty_desc_room_from_index`,
`persist_folds_lost_core_sidecar_invite_family_sees_hist_requests`,
`persist_folds_lost_core_sidecar_send_on_hist_reuses_live`,
`persist_folds_empty_topic_room_live_is_not_direct`,
`persist_folds_lost_core_sidecar_second_dm_does_not_steal_hist`,
`persist_folds_lost_core_sidecar_delete_live_purges_hist_from_index`,
`conversation_index::record_fold_roundtrips_and_remove_group_forgets_bind`,
`conversation_index::migrates_v2_schema_adding_historical_fold_table`.

Compose persist-folds media-reconcile hole closed after this commit:
`existingPublishedMediaUrls` paged only the listed live id. A remounted
0.8 `image.jpg` then looked like the new send’s blossom URL. Exclude
hist attachments via `publishedMediaUrlsFromFamilyPages`. Remainder
ticks now also page hidden siblings (`conversationRefreshIds` at the
`handleConversationChange` call site, matching iOS
`snConversationRefreshIds`). iOS has no twin of this upload-reconcile
path. Pins:
`ConversationFoldTest.publishedMediaUrlsIncludeHiddenHistoricalSibling`,
`ConversationFoldTest.conversationChangeTargetPrefersListedLiveSibling`.

Pending 0.8 outbox hole closed after this commit: first 0.9
`retry_outbox` used only live MLS ids, so `retryable_events` deleted a
recovered-id pending row and `messages()` painted the mine bubble Sent.
Active ids now include recovered 0.8 groups and fold aliases. Historical
ciphertext is not republished on the 0.9 wire. Leaving the row Pending
then painted eternal Sending, and a retry tap still published the dead
wrapper (a relay ACK would flip it Sent). Those rows now mark Failed
once; `retry_message` refuses with `HistoricalProtocolRetry` before
flipping them back to Pending (R-046). Do not include fold aliases of
a live group in the publishable set — after resume the hist wrapper is
still 0.8. Pin:
`e2e.rs::recovered_08_pending_outbox_survives_upgrade_connect`,
`outbox.rs::retryable_events_keeps_unpublishable_active_rows_and_marks_failed`.

Host fold-blob prune hole closed after this commit: an empty
`chats()` / `$groups` listing (node closed, reconnect, first sink)
must not persist an empty `sonar.historicalFolds` map. Wipe and
leave already forget the family. Pins:
`ConversationFoldTest.emptyAuthoritativeListingDoesNotPruneFolds`,
`SonarConversationFoldTests` empty `listedIds` + `listedAuthoritative`.

Compose closed-node listing hole closed after this commit:
`SonarCore.chats()` returned `[]` when the node was closed, and
`refreshChats` treated that as a real empty account — wiping the
in-memory list and persisting a blank chat snapshot. A closed node
now throws; a failed listing keeps the painted snapshot. An empty
success list (no chats) still replaces. iOS only assigns `groups`
after a successful FFI read. Pin:
`ConversationFoldTest.closedNodeListingDoesNotReplaceOrPersistCachedChats`.

Same hole class on the other listing helpers: `conversationSummaries()`,
`recentMessagePages()`, `pendingGroupInvites()`, and `messages()` also
returned `[]` on a closed node. Housekeeping / `markGroupsRead` already
keep badges when the probe is `null`, but an empty *success* still
clears them; `refreshChatsInner` used
`pendingGroupInvites().getOrDefault(emptyList())` and wiped recovered
pending welcomes. Those actuals now throw; invite assign uses
`pendingInvitesOrCached`. iOS `pendingGroupInvites()` already throws and
only assigns on a successful `try`. Pin:
`ConversationFoldTest.closedNodeInviteProbeDoesNotClearCachedWelcomes`.

iOS `conversationSummaries()` used `readOnlyNonThrowing` and answered
`[]` on a closed node, so `publishUnread` wiped every badge. It now
throws; hosts skip unread publish when the probe is nil
(`SNUnreadCounts.shouldPublish` / Compose `shouldApplyUnreadCounts`).
Empty success still clears stale dots. Pin:
`ConversationFoldTest.closedNodeInviteProbeDoesNotClearCachedWelcomes`
(`shouldApplyUnreadCounts`),
`SNUnreadCountsTests.failedSummariesProbeDoesNotPublishUnread`.

Catch-up / media hist-id hole closed after this commit:
`prefer_catchup_group` looked up the raw MLS hex in `engine.groups()`.
A recovered 0.8 id is hidden after fold, so opening that row (snapshot
still lists it, remount has not swapped nav) cleared the preference
and 0.9 traffic sat behind every other chat. Restore the index bind
and remap onto the live sibling first. `fetch_media` /
`fetch_media_to_file` restore the same way so a hist-id fetch of a
0.9 blob can use the live exporter after sidecar loss. Pin:
`client::tests::prefer_catchup_maps_folded_hist_to_live_mls_hex`.

Still missing here: device 0.8 in-place upgrade, White Noise iOS interop, cold-start `t0→t4`.

First-paint host hole closed after `21ddc90e`: Compose `encodeChatSnapshot`
now persists `isDirect`. A missing 6th field / Codable key defaults
not-direct so a recovered room stays visible on the first-upgrade paint.
In-memory constructors (`SonarChat.isDirect`, `MarmotGroup.init`) match
that decode default — DMs opt in — so a remounted empty-topic room
cannot fold onto the welcomer 1:1 if a host constructor omits the flag.
Pins: `ConversationFoldTest.chatSnapshotPreservesRecoveredRoomIsDirect`,
`ConversationFoldTest.legacyChatSnapshotWithoutIsDirectDoesNotFoldAsDirect`,
`ConversationFoldTest.emptyTopicResumedRoomDoesNotFoldOntoWelcomerDm`,
`MarmotProfileCacheTests.chatSnapshotPreservesRecoveredRoomIsDirect`,
`MarmotProfileCacheTests.legacyChatSnapshotWithoutIsDirectDoesNotFoldAsDirect`,
`MarmotProfileCacheTests.emptyTopicResumedRoomDoesNotFoldOntoWelcomerDm`.
