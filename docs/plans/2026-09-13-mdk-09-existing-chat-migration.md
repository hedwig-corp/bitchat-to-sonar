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
| Conversation index | preserved + seeded from sidecar | fold copies the recovered row onto the live id; `conversation_summaries()` hides the historical sibling; `mark_conversation_read` clears the whole fold family | none |
| Compose (`apps/sonar`) | `groups()` includes recovered rows; `GroupInfo.is_direct` keeps rooms off the 1:1 npub fold. First-paint snapshot now persists `isDirect` (6th field) so a two-member recovered room does not fold onto the welcomer DM before `chats()` returns. Pre-`isDirect` blobs default **not-direct** in memory so the room stays visible; startup rewrite of old blobs omits the flag until `groups()` returns so invented `false` is not durable. A joined named room with only one known peer stays a room (`historical_resume_is_direct` matches live `group_is_direct`). | send prefers newest duplicate; toast/banner if KeyPackage missing; recovered 0.8 attachments show a non-retryable “older Sonar” state | none |
| iOS (`ios/`) | same (`MarmotGroup.isDirect` in the Codable snapshot). Old snapshots without the key default not-direct in memory. `SNMarmotChatSnapshotCache.load` strips leftover message bodies without re-encoding groups, so invented `isDirect=false` is not stamped durable before FFI `groups()`. | same | none |
| Mesh | untouched | untouched | none |

Resume-chat fold: recovered 0.8 rows appear in FFI `groups()` with
members inferred from the transcript. A send on that id creates a new
0.9 group with the same peer npubs, records
`.sonar-historical-folds.json`, and `messages()` unions both ids so
history is not wiped or split. A pending welcome with
`member_count > 2` never uses `start_dm` even if only the welcomer is
known — that would fold the room onto a 1:1. `maybe_fold_new_group`
(new DM with the same known peer) is the same hazard and must skip
recovered rooms; rooms resume only via `resolve_send_group`. Hosts
still collapse a *person* by npub (R-003 / R-045). Peer still on 0.8:
`KeyPackageNotFound` → "Waiting for them to update Sonar".

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

Re-run on this cloud agent after the joined-room `is_direct` pin. All green.

| Gate | Result |
| --- | --- |
| `--lib` `--` `mdk08_migrate` `historical_fold` `account_backup` | 95 passed |
| `--lib` `--` `client::tests` | 72 passed |
| `--test persistence` | 29 passed (includes `mdk08_named_room_with_one_known_peer_is_not_direct`) |
| `--test e2e` `recovered_08` | 7 passed |
| Compose `ConversationFoldTest` (`:composeApp:jvmTest`) | 31 passed (includes first-paint `isDirect` pins) |
| `scripts/check-regression-ledger.sh` | 236 citations |

Joined-room hole closed after `900f9788`: a recovered named 0.8 room with
only one known peer no longer resumes as `start_dm`. Extract copies
`groups.description` and processed-welcome `member_count`;
`historical_resume_is_direct` matches live `group_is_direct`. Early
`metadata_backfill=complete` markers re-run as `v2` so already-quarantined
baks pick up the new sidecars.

Still missing here: device 0.8 in-place upgrade, White Noise iOS interop, cold-start `t0→t4`.

First-paint host hole closed after `21ddc90e`: Compose `encodeChatSnapshot`
now persists `isDirect`. A missing 6th field / Codable key defaults
not-direct so a recovered room stays visible on the first-upgrade paint.
Pins: `ConversationFoldTest.chatSnapshotPreservesRecoveredRoomIsDirect`,
`ConversationFoldTest.legacyChatSnapshotWithoutIsDirectDoesNotFoldAsDirect`,
`MarmotProfileCacheTests.chatSnapshotPreservesRecoveredRoomIsDirect`,
`MarmotProfileCacheTests.legacyChatSnapshotWithoutIsDirectDoesNotFoldAsDirect`.
