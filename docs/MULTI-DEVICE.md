# Multi-device (one nsec, several machines, used together)

Status: design. Depends on the MDK 0.9 port
([`docs/plans/2026-07-18-mdk-09-multi-device.md`](plans/2026-07-18-mdk-09-multi-device.md)).
Date: 2026-07-18.

This describes how one Sonar account — one nsec, one npub — runs on more than
one machine **at the same time** (e.g. macOS desktop and an Android phone, both
live, both sending and receiving). It is not a one-shot transfer to a new phone,
and not a cold-standby device. Both devices are first-class members of your
chats simultaneously.

## The core idea: one account, many device leaves

Your account is your Nostr identity — one npub, derived from your nsec. That key
is the same on every machine. What is **not** shared is MLS key material:

- Marmot chats are MLS groups. Every member of a group occupies a **leaf** in
  the group's ratchet tree, and each leaf has its own MLS signing key.
- Multi-device means one account owns **several leaves** — one per device — in
  each group, instead of one. Each of your devices generates and holds its own
  MLS key, and keeps its own encrypted local database. There is no shared MLS
  state and no key copying between your machines.
- MDK 0.9 models exactly this: an "account-device session" is one encrypted
  SQLite database for one *account-device* identity. The account (npub) is the
  stable id; the device leaf is the per-machine MLS presence under it.

```
                          your account (one npub, from your nsec)
                          /                                      \
              device identity proof                    device identity proof
                        /                                          \
        Sonar on your Mac                                   Sonar on your Pixel
     own MLS key + own DB                                own MLS key + own DB
                        \                                          /
                         \                 MLS group              /
                          [ You·Mac ] [ Alice ] [ Bob ] [ You·Pixel ]
                     every message encrypts to all four leaves
```

Alice and Bob are ordinary other members. `You·Mac` and `You·Pixel` are two
leaves of *your* identity. A message any member sends is encrypted to all leaves
in the tree, so both of your devices can read it, and either can send.

## Logging in on a new machine

You install Sonar on a second machine and enter your nsec. What happens:

1. **Log in with your nsec.** Same npub, same profile (kind-0), same Breez
   wallet (the wallet is already derived from the identity, so it works
   cross-device from the same nsec — see the wallet-from-identity memory).
2. **The device mints its own MLS key** and publishes a KeyPackage
   (kind 30443) to your NIP-65 outbox relays. A KeyPackage is the "you may add
   me to a group" credential.
3. **An identity proof binds the device to your npub.** A kind-450 event
   (MIP-06 identity-proof pattern) signed by your account key states that this
   device leaf belongs to your identity. This is what lets other clients fold
   the new leaf into *your* person rather than treating it as a stranger.
4. **An existing member adds the new leaf.** MLS state cannot be conjured from
   the nsec alone — someone already inside each group must commit an "add" for
   the new leaf and send it a welcome. The natural adder is **your own other
   device**: it is already in every one of your groups and trusts your account
   key by definition. If it is offline, any peer client that sees your new
   KeyPackage plus a valid identity proof can perform the add.
5. **Both devices are live.** Once a group has processed the add, that
   conversation is writable from the new machine, and every subsequent message
   encrypts to all your leaves.

Identity, profile, and wallet appear **instantly** on the new machine. Each
conversation becomes writable only once its group has processed the add — which
follows the XChat startup rule: paint pending conversations from local state
immediately, reconcile to writable in the background as welcomes arrive. Login
never blocks on relay connect or per-group setup.

## Using two devices at the same time

- **Independent databases, independent sync.** Each device keeps its own
  encrypted SQLite DB and syncs from relays on its own. Your Mac and your Pixel
  can drift briefly and then converge. Nothing is copied device-to-device.
- **Simultaneous sending is a solved problem, not a Sonar design.** Two of your
  devices committing to the same group at the same epoch is exactly the
  concurrent-commit race the MDK 0.9 engine handles: fork resolution,
  losing-committer invalidation, epoch-gap backfill, membership-fork replay. We
  rely on that machinery; we do not re-implement it. (This is the main reason
  the design follows what MDK 0.9 blesses instead of reviving the bespoke
  link-code flow from the shelved PR #195.)
- **Peers see one person, not two.** Other members' UIs fold your leaves by
  npub, so a chat with you shows one participant even though you occupy two
  leaves. This mirrors Sonar's existing conversation-unification invariant
  (fold a person across transports — see `docs/REGRESSIONS.md`), applied to
  leaves instead of transports.

## Message history on a new device

MLS gives forward secrecy: a leaf can only decrypt from the epoch at which it
joined. A newly-added device **cannot read messages sent before it was added** —
they are cryptographically inaccessible, by design. A new device sees:

- new messages from the moment it joins each group, and
- whatever older messages the relays still hold that it is entitled to decrypt
  after its join epoch (a bounded backfill window).

True "log in and all your history is there" requires an explicit **encrypted
history transfer** (export from an existing device, or an encrypted Blossom
backup) — a tracked follow-up, not part of the first multi-device cut. The gap
is honest and expected, the same as Signal-style linked devices starting empty.

## What is per-device vs account-level

| Stays per-device                          | Stays account-level (same on every device) |
|-------------------------------------------|--------------------------------------------|
| MLS signing key + leaf                     | npub / nsec (your identity)                |
| Encrypted local SQLite database            | Nickname + kind-0 profile                  |
| Local DB encryption key                    | Breez wallet (derived from the nsec)       |
| BLE mesh identity (a radio is physical)    | Group membership (you, as a person)        |
| Push token (owner-authenticated gossip)    |                                            |

The BLE mesh leg stays single-device: mesh identity is tied to a physical
radio, so multi-device applies to the Marmot / White Noise (relay) leg only.

## Removing or retiring a device

Losing a laptop, or retiring an old phone, means removing that device's leaf
from every group. Two mechanisms:

- **Interim:** a per-group remove of the retired leaf, plus `sign_out` with
  relay KeyPackage cleanup so the stale KeyPackage stops being addable.
- **Target:** MIP-06's `IdentityRemove` custom proposal removes *every* leaf of
  a given identity atomically, resolved to leaves at commit time so leaves added
  during the race window are still caught. This is the clean revoke primitive; a
  Settings → Devices screen (list, label, revoke) sits on top of it.

## Interop note

The device leaf + identity-proof model is the White Noise / Marmot native
shape, so a Sonar device and a White Noise device under the same identity are
just two leaves to each other — the same reason the MDK 0.9 port restores
Sonar ↔ White Noise iOS interoperability.

## Open design questions

- **Add authorization.** Does MIP-06 finalize on pure-nsec login being enough
  to add a new device, or does it require an existing device to co-sign the
  addition (anti-theft, so a stolen nsec alone cannot silently join your
  chats)? This decides whether the login UX is "type your nsec" or adds a
  confirm-on-existing-device step. Resolve by reading the MIP-06 PR on
  `marmot-protocol/marmot` before implementing Stage 2.
- **Backfill depth.** How far back does a new device's relay backfill reach
  before the encrypted-history-transfer follow-up lands?
- **Offline adder.** If your only other device is offline at login time, which
  peer client is expected to perform the add, and what is the fallback if none
  is online?
