# Moving a Sonar account (and chats) to a new phone

Date: 2026-07-10. Status: reviewed 2026-07-10 (Fable 5, grounded in vendored
`mdk-core` @ e8cd584) — see "Review corrections" below. Approach B selected
for implementation.

## Review corrections (2026-07-10)

Three claims in the original draft were wrong; all three make Approach B easier:

1. **No KeyPackage overwrite / account fork.** MDK generates a fresh random
   64-hex `d` tag per KeyPackage (`key_packages.rs`, MIP-00), so a new device's
   KeyPackage coexists with the old device's under a different addressable
   slot. (Separate pre-existing wart: Sonar never passes `existing_d_tag`, so
   every relay-connect republish mints a NEW slot — slot proliferation.)
2. **No send fan-out needed.** MLS application messages encrypt to the group
   epoch; every leaf decrypts. Once the second leaf is in, send/receive works
   unmodified. `mine:` is pubkey-based (`marmot.rs`), so cross-device own
   messages render correctly.
3. **No MIP change required.** MDK already models membership by Nostr identity:
   "Multiple MLS leaves may legitimately carry the same Nostr identity"
   (`state_validation.rs`). White Noise uses the same library; a device-add is
   an ordinary `add_members` commit to peers.

Keystone: **the old device commits the new device in itself** — it is an admin
in every Sonar 1:1 DM (`create_group` makes all members admins). No peer
cooperation needed.

Confirmed v1 gaps (tracked, not blockers):
- **Device revocation impossible in v1**: `remove_members` resolves pubkey →
  ALL leaves and hard-blocks own-pubkey removal (`groups.rs:1190`). Needs MDK
  leaf-index removal upstream.
- **Non-admin groups**: `add_members` requires admin; groups where the user is
  not an admin cannot receive the second device in v1.
- **History does not move** (MLS joins at the current epoch) — that is
  Approach C, explicitly out of scope for B.

## The finding that shapes everything

The dev's framing — *"encrypted backup to a Blossom server… that's chat history
though, not keys and state. So you add the other device to the chat then sync
chat history"* — is **correct about the split, and the second half is the hard
half.** Concretely, in this codebase:

| Thing | Where it lives | Can it be reconstructed from the nsec? |
|---|---|---|
| Account key (`nsec`) | Keychain `marmot-nsec` | it *is* the seed |
| Lightning wallet | Breez, restored from nsec | yes, free |
| Nostr profile / relay lists | relays (kind 0, 10050…) | yes, refetch |
| **MLS group state** (ratchet, leaf HPKE private keys, epoch secrets) | `marmot.sqlite` (SQLCipher, `MdkSqliteStorage`) | **no — random, device-bound** |
| Chat transcript | same `marmot.sqlite` (MDK message rows) | no, but it's just data |
| SQLCipher DB key | Keychain `marmot-db-key`, 32 random bytes | **no — random today** |
| BLE mesh Noise static key | Keychain (`identity_*`), random per install | **no — random** |

Two consequences:

1. **A new install with the same nsec is a different Marmot member.** It can
   read gift-wrapped Welcomes addressed to the npub, but it cannot decrypt them:
   the KeyPackage init private key that a Welcome encrypts to only ever existed
   in the old phone's `marmot.sqlite`. Same for every kind-445 group message —
   no exporter secret, no leaf key, nothing. Restoring "chat history" onto that
   install gives you a read-only museum: old messages render, no new message in
   any existing group decrypts, and you cannot send.

2. **Publishing a KeyPackage from the new phone is actively harmful today.**
   Kind 30443 is addressable/replaceable. `publish_key_package_background()`
   fires on every relay connect (`core/sonar-core/src/client.rs:1112`). Boot the
   new phone with the same nsec and it overwrites the relay-side KeyPackage for
   that npub. Anyone who *starts a new chat* with you from then on reaches the
   new device's leaf; every *existing* group still routes to the old device's
   leaf. The account silently forks. `fetch_all_key_packages()`
   (`client.rs:1133`) already anticipates "multiple devices, or a stale slot" and
   `start_dm_with_key_package()` exists to pick among them — so the split is
   half-anticipated but nothing resolves it.

Also easy to miss: the BLE Noise static key is a separate random keychain item,
and `peerID = SHA256(noise_pubkey)[:8]`. A new phone gets a new fingerprint, so
mesh peers see a stranger and the fold logic in the "one conversation per person"
rule cannot join the legs. Whatever migration path we pick, the Noise key must
move with the nsec or we knowingly break mesh identity.

## What Signal does (per the Signal-First rule)

Signal ships **two distinct mechanisms**, and it's worth naming them separately
because Sonar keeps conflating them:

- **Device transfer** (`Transfer account to new phone`, Signal-Android
  `DeviceTransferActivity` / iOS `DeviceTransferService`): QR pairing, direct
  local Wi-Fi/mDNS + TLS link, streams the *entire* SQLCipher database and the
  identity keys, and **deactivates the source device** at the end. One device
  identity, moved. No server, no long-lived backup blob.
- **Linked devices** (Desktop/iPad): a genuinely new identity key + prekeys,
  registered under the same account, added as a second recipient to every
  session. Signal historically shipped this with *no* history sync, and only
  recently added a bounded transfer of recent history over the link.

Signal never tries to reconstruct ratchet state from a backup on a *different*
identity. Its remote backup (SVR/Backups) restores onto an install that then
re-establishes sessions from scratch — sessions heal because Double Ratchet
sessions are pairwise and cheap to re-create. **MLS groups are not.** Re-creating
an MLS leaf requires a commit from someone already in the group. That is the
whole difficulty, and it is why "add the other device to the chat" is a protocol
task, not a client task.

## Approaches

### A. Move, don't clone — device-to-device transfer
Pair old↔new by QR, open a local encrypted channel (BLE mesh already exists;
Wi-Fi/mDNS + Noise is the same primitive), stream `marmot.sqlite` + sidecars
(`.sonar-sync.json`, outbox, push cache) + `marmot-nsec` + `marmot-db-key` +
Noise static key, verify a hash, then **wipe the source**. The new phone *is*
the old leaf: every group, every epoch, every message, zero peer cooperation.

- Affected: `ios/bitchat/Views/Sonar/SonarAppStore.swift` (db config, keychain),
  `ios/bitchat/Services/KeychainManager.swift`, `core/sonar-core/src/marmot.rs`
  (needs an `export`/checkpoint that quiesces WAL), the Compose equivalents in
  `apps/sonar/`, plus a new pairing/transfer UI on both.
- Gains: correct MLS semantics (a leaf may exist in exactly one place), full
  history, works offline, no server, no new Nostr kind, no peer changes.
- Costs: both phones must be present and online *at the same time*; useless when
  the old phone is lost, stolen, or bricked — which is the case users actually
  hit. Requires disciplined source-wipe: if the clone survives, two devices run
  the same ratchet and MLS forward secrecy is broken (and MDK will desync on the
  first commit).
- Effort: **M** (mechanically simple, the ceremony and the wipe are the work).

### B. Second leaf — real multi-device
New device generates its own MLS credential, publishes a KeyPackage under a
distinct `d` tag, and announces "npub X, device 2" (a new addressable kind, or a
tag on the Sonar descriptor in `sonar_descriptor.rs`). Peers' clients notice a
known member's unknown device and issue an `add_members` commit
(`marmot.rs:425`) so the new leaf joins the group at the current epoch. Sending
must fan out to every leaf of a recipient npub; `fetch_key_packages_for_members`
(`client.rs:1165`) must stop picking one.

- Affected: `sonar-core/src/marmot.rs`, `client.rs` (KeyPackage fetch/select,
  group membership, self-message filtering), `sonar_descriptor.rs`, both hosts'
  conversation identity/fold logic, and — unavoidably — a MIP-level agreement so
  White Noise and other Marmot clients do the same thing.
- Gains: the only path that survives a *lost* phone; also unlocks desktop-as-a-
  second-device, which `apps/sonar/` jvm already wants.
- Costs: large. Adding a leaf mutates the group, so it needs an admin (in 1:1
  Sonar DMs both parties are admins — fine; in groups, not always). It leaks
  device count. It does **not** move history (MLS carries no backlog). It is
  cross-client protocol work Sonar cannot land unilaterally. And an attacker who
  steals your nsec can add *their* device to all your chats unless leaf addition
  requires an out-of-band confirmation from an existing leaf.
- Effort: **L** (protocol + core + two apps + interop).

### C. Encrypted transcript backup to Blossom
Periodically serialize the transcript (messages, conversation summaries, media
refs) into an encrypted blob, key derived from the nsec (HKDF), upload to the
user's Blossom servers — the kind-10063 server list is already read/written
(`client.rs:2192`) and `sonar-stickers/src/blossom.rs` has the URL/hash
primitives. On a new device, import nsec → derive key → fetch → hydrate the local
DB.

- Affected: new `sonar-core` backup module + a Blossom *upload* client (only
  validation helpers exist today), `conversation_index.rs`, both hosts.
- Gains: survives a lost phone; cheap; recovers the thing users emotionally care
  about (their messages, their photos).
- Costs: **restores zero cryptographic state.** By itself it produces the
  read-only-museum failure above. Also: metadata exposure (blob size, upload
  cadence, which Blossom server), and the derived-key design means nsec
  compromise retroactively decrypts every backup.
- Effort: **M**.

### D. Prerequisite for B *and* C: derive the DB key from the nsec
Today `marmot-db-key` is 32 random bytes minted on first run
(`docs/MARMOT-PERSISTENCE.md`, "Key ownership"). Replace with
`HKDF(nsec, info="sonar-marmot-db-v1")` behind a migration that rekeys the
existing SQLCipher file. Then *any* blob containing the DB is self-describing
given the nsec, and A stops needing to ship a separate secret.

- Costs: weakens the current property that the DB key never leaves the Secure
  Enclave-backed keychain and is independent of the account key. Must not violate
  the Account Key Durability Rule — the rekey must be update-in-place, never
  delete-then-add.
- Effort: **S**, but it is a one-way door.

## Approach B v1 implementation shape (post-review)

Flow ("link a new device"):

1. **New device**: import nsec → connect → publish its KeyPackage (fresh `d`
   slot) → display a short link code derived from the KeyPackage event
   (e.g. first bytes of the event id / `d` tag) for out-of-band confirmation.
2. **Old device**: Settings → "Link new device" → `fetch_all_key_packages(own
   npub)` → user confirms the entry matching the new device's displayed code
   (solves stale-slot ambiguity AND authenticates the request; note only the
   nsec holder can sign a kind-30443 for this npub anyway).
3. **Old device**: for each Marmot group where we are admin:
   `add_members(group, [new_device_kp])` → publish evolution event → gift-wrap
   welcome to own npub → publish → `merge_pending_commit`. Reuse the existing
   partial-delivery rules. Report per-group progress; collect non-admin groups
   into a visible "could not link" list.
4. **New device**: welcomes arrive on the existing gift-wrap subscription.
   Welcomes whose rumor is authored by our own npub are **auto-accepted**
   (self-authored ⇒ nsec holder authorized it); foreign welcomes keep the
   manual-accept path.
5. Both devices now hold independent leaves in the same groups; messaging
   works with no send-path changes. New device sees history from join epoch
   forward only.

Affected code:
- `core/sonar-core/src/client.rs` — link-device API: enumerate own KeyPackages,
  add-device-to-all-admin-groups loop, auto-accept own welcomes.
- `core/sonar-core/src/marmot.rs` — nothing structural (add_members exists);
  possibly a helper to distinguish own-npub welcomes.
- `core/sonar-ffi/src/lib.rs` — expose the link API + progress events.
- `ios/bitchat` — Settings "Linked devices" screen (show code on new device,
  confirm+link on old device).
- `apps/sonar` — same screen in Compose (Cross-Platform Feature Rule).
- `core/sonar-cli` — `link-device` subcommand for headless testing.

## Recommendation

**Shipped: Approach B in PR #195.** The review corrections above overturned the
original draft's reasons for preferring A first — the account fork it feared
does not exist (fresh random `d` tag per KeyPackage), no send fan-out is needed,
and no MIP change is required — which makes B correct on day one, not just the
long-term goal. So B is what shipped: link a new device as a second MLS leaf,
old device commits it into every admin group, new device auto-accepts its own
sealed welcome.

C (encrypted transcript backup to Blossom) remains the next follow-up so a
*lost* phone still recovers its history; B does not move history (MLS joins at
the current epoch), and the UI states this. A (device-to-device transfer) is no
longer on the critical path but is still a reasonable future addition for the
lost-nothing "both phones in hand" case.

The original draft's KeyPackage-fork safety concern turned out to be moot: MDK
already mints a fresh random `d` tag per KeyPackage, so an imported-nsec install
coexists with the old device's slot rather than replacing it. `existing_d_tag`
reuse to curb slot proliferation on relay-connect republish remains an open
cleanup (tracked below).

### Historical note (original draft recommendation)

The pre-review draft recommended "A now, C next, B as the tracked protocol
goal," on the belief that B required a MIP change and risked a silent account
fork. Both premises were disproven while grounding the plan in the vendored
`mdk-core` — see "Review corrections" at the top. Kept here only so the
decision trail is legible.

## Open questions

- Does MDK's `tags_30443` emit a fixed `d` tag, or one derived from the key
  package? Determines whether the fork in (2) is real today or only latent. Read
  `mdk-core`'s `create_key_package_for_event` — I inferred replaceability from
  the kind being addressable, I did not confirm the tag value.
- Marmot MIP status for multi-device: is there an existing MIP draft, or does
  Sonar have to propose one? Affects whether B is "implement" or "design + sell".
- Group admin constraint: in a non-DM Marmot group, can a member add their own
  second leaf, or must an admin commit it? If the latter, B degrades badly for
  groups you don't administer.
- Does White Noise tolerate two leaves with the same credential/npub in one
  group, or does it dedupe members by pubkey and break?
- Transfer wipe policy: hard-wipe the source device, or leave it read-only? A
  read-only source is friendlier and still MLS-safe, but only if it can never
  emit a commit or a message.
