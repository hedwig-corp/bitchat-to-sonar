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

What the user does **not** keep automatically:

- The ability to send into the old 0.8 MLS group. That group is dead on
  this device once the 0.9 store is the live engine.
- Media decrypt keys that lived only in 0.8 imeta rows (v1 copies text;
  MIP-04 attachment recovery is a follow-up).
- Pending 0.8 welcomes that were never accepted.

## Runtime path (implemented on this PR)

`MarmotEngine::persistent`:

1. Try MDK 0.9 open (passphrase key, `defer_group_hydration`).
2. If the file is plaintext `SQLite format 3`, wipe + recreate (existing
   self-heal).
3. If 0.9 open fails and the file exists:
   - Open with the 0.8 raw key.
   - If `messages` is readable, copy `kind = 9` rows onto the transcript
     sidecar and group titles onto `.sonar-historical-groups.json`.
   - Rename the 0.8 file (and WAL/SHM) to `*.mdk08.bak`.
   - Create a fresh 0.9 store at the original path.
   - If 0.9 create fails, rename the 0.8 file back. Never delete it.
4. Wrong key / unknown file: return `protocol migration required`. Do not
   wipe, do not quarantine.

`ConversationIndex::materialize_from` then seeds empty index rows from
transcript group ids, so chat-list first paint does not wait on live MLS
groups (Signal-comparable / XChat startup). Existing index files are left
alone.

Guarded by:

- `mdk08_migrate::tests::extracts_plaintext_chat_and_ignores_non_chat_rows`
- `mdk08_migrate::tests::wrong_key_is_not_a_0_8_store`
- `persistence::mdk08_store_decrypts_and_moves_plaintext_without_wiping`
- `persistence::mdk08_store_wrong_key_is_left_intact`
- `marmot::historical_fold_tests::recovered_history_survives_fold_onto_new_group`
- `e2e::recovered_08_chat_resumes_on_a_new_09_group_through_a_relay`
- `e2e::recovered_08_group_resumes_on_a_new_09_group_through_a_relay`
- `e2e::recovered_08_group_resumes_with_whichever_peers_have_updated`
- `conversation_index::copy_summary_promotes_recovered_row_onto_live_id`
- `ConversationFoldTest.recoveredAndResumedDirectChatsRenderOnceByPeer`
- existing `wrong_key_cannot_open_existing_db` / `self_heals_an_unencrypted_legacy_database`

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
cargo test -p sonar-core --test e2e recovered_08_chat_resumes
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

Device / interop (not substitutable by unit tests):

- Existing 0.8 install → in-place upgrade of this build: same npub,
  wallet intact, Marmot chat list shows recovered rows, opening a
  recovered chat paints local history without waiting on relays.
- Send on a recovered chat creates a **new** 0.9 group and does not
  delete the old transcript.
- Sonar 0.9.14 ↔ White Noise iOS 0.9 DM + group, both directions.
- Sonar 0.9.14 → leftover 0.8 peer: typed mismatch, no wipe, mesh still
  sends if the conversation is folded.
- Cold-start `t0→t4` stays within `docs/PERFORMANCE.md` noise;
  migration is local disk only and must not sit on the relay path.

## Surfaces

| Surface | History | Live 0.9 send | Gap |
| --- | --- | --- | --- |
| Rust core | decrypt-and-move (this PR) | `send_*` resumes via `start_dm` / `create_group` and records a fold. Direct chats auto-join; recovered rooms use the existing pending-invite accept path and include whoever already published a 0.9 KeyPackage | adding late-updating members later |
| Conversation index | preserved + seeded from sidecar | fold copies the recovered row onto the live id; `conversation_summaries()` hides the historical sibling; `mark_conversation_read` clears the whole fold family | none |
| Compose (`apps/sonar`) | `groups()` includes recovered rows; transcript merge by npub | send prefers newest duplicate; toast/banner if KeyPackage missing | none |
| iOS (`ios/`) | same | same | none |
| Mesh | untouched | untouched | none |

Resume-chat fold: recovered 0.8 rows appear in FFI `groups()` with
members inferred from the transcript. A send on that id creates a new
0.9 group with the same peer npubs, records
`.sonar-historical-folds.json`, and `messages()` unions both ids so
history is not wiped or split. Hosts still collapse the person by npub
(R-003). Peer still on 0.8: `KeyPackageNotFound` → "Waiting for them
to update Sonar".

## Explicitly out of scope here

- Stage 2 multi-device (same nsec, several live devices) — #327
- Dual-stack 0.8+0.9 sender
- Importing 0.8 MLS secrets into a 0.9 session
- MIP-04 media-key recovery from 0.8 `imeta` / `event` JSON
- Deleting `*.mdk08.bak` automatically
- Cold-start bench numbers on this machine (Debug + `SONAR_BENCH_NSEC`)

## Ship rule

Stay draft until:

1. The persistence / extract / fold tests above are green in CI.
2. The 0.9.14 group-scale table is committed.
3. Device upgrade + White Noise interop still need a human pass
   (cannot be substituted by unit tests).
