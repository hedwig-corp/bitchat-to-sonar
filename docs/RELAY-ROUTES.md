# Relay routes: being found without sharing a relay

Tracking issue: #626. Code: `core/sonar-core/src/relay_routes.rs`, wired into
`client.rs`. Both apps get it through the core; there is no host UI change.

## The problem

Sonar's Marmot pool is five hardcoded relays, and before this change every
publish went there and nowhere else: no kind `10002` (NIP-65 outbox list), no
kind `10050` (NIP-17 inbox list), nothing on the public indexer relays other
Nostr clients read. A client not sitting on one of those five relays could not
find a Sonar profile or KeyPackage. White Noise sends welcomes only to the
recipient's `10050`, with no fallback, so without one a White Noise user can
never invite a Sonar user.

## What the core does

Two relay pools, on purpose:

| Pool | Relays | Used for |
|---|---|---|
| Marmot pool (`SonarClient::nostr`) | the five configured relays | everything it did before: subscriptions, sync, sends, KeyPackage, profile |
| Route pool (`RelayRouter`) | lookup and indexer relays, connected on demand | looking our records up, copying them to indexers, the KeyPackage copy for an adopted list |

They never mix. nostr-sdk's pool-wide `send_event` reaches every WRITE relay
and `subscribe` every READ relay, and a targeted `send_event_to` refuses a
relay without WRITE, so an indexer in the Marmot pool would receive every
group message. `client::tests::lookup_relays_never_join_the_marmot_pool` pins
this.

### Distribution (`RelayRouter::distribute_account_records`)

Runs in the background after every KeyPackage publish (i.e. on relay connect),
and is skipped when the last complete pass is under 24 h old. For each of
`10002`, `10050`, `10051` and kind `0` it looks the current event up on our
relays **and** the lookup set, then:

| Lookup outcome | Action |
|---|---|
| no lookup relay answered | publish **nothing**; retry next connect |
| nothing found, fewer than the quorum answered | **deferred**: publish nothing for that kind; retry next connect |
| nothing found, quorum answered | publish Sonar's default to our relays and the indexers |
| found (on any relay), names one of our relays | copy the existing signed event unchanged |
| found, does not name us (another client's list) | leave it alone; **adopt** it — the KeyPackage also goes to its write set |
| kind `0` found | copy it to the indexers that take profiles; never invent one |

Evidence rules, because kinds `10002`/`10050`/`0` are replaceable and a
default published over an imported account's real list replaces it
network-wide:

- **Existence** is evidence from a single relay.
- **Absence** needs a majority of the lookup relays asked (`absence_quorum`:
  3 of 5, 2 of 2). Two dead indexers must not block every account forever —
  relay.nostr.band went dark without notice — while one or two answers out of
  five are never enough. With a lookup set configured, our own relays
  answering "nothing" proves nothing: an imported account usually lives on the
  indexers only. With no lookup set, one own relay answering decides.
- **The newest event** is chosen by NIP-01 order: newest `created_at`, lowest
  id on a tie — the one relays keep.
- **Stamping.** A pass counts as done (and suppresses the next 24 h) only if
  it reached the quorum, and each record landed on one of our relays and, when
  any indexer takes its kind, on one indexer. Otherwise the next connect runs
  it again. A pass short of the quorum still acts on what it found — an
  adopted list's relays are kept for the KeyPackage copy — it just claims no
  freshness.

The profile publish (`publish_profile`, and the connect-time republish) uses
the same lookup: a profile found on any relay — ours included — is merged
over, whatever the indexers did; it refuses to publish only when none was
found and the quorum was not reached — so a restore on a flaky network cannot
replace a profile set in another client. A brand-new account whose first
publish is refused this way gets it out on the next connect. The indexer copy
of a published profile is spawned, not awaited, so a rename never waits on
indexer handshakes; the next distribution pass re-copies anything that did
not land.

Defaults: `10002` = our relays, unmarked; `10050` = the Sonar relay plus two
others (NIP-17 keeps it small); `10051` = the write set, for clients that
still read the pre-2026-06 kind. Indexers are never written into the lists.

Indexers and what each accepts (NIP-11 and relay sources, checked 2026-09-28):

| Relay | Kinds |
|---|---|
| `purplepag.es` | 0, 10002, 10050, 10051 |
| `user.kindpag.es` | 0, 10002 |
| `indexer.coracle.social` | 10002 |
| `profiles.nostr1.com` | 0, 10002, 10050 |
| `relay.ditto.pub` | 0, 10002, 10050 |
| `index.hzrd149.com` | 0, 10002 |

No indexer stores kind `30443`, so KeyPackages stay on the write relays the
lists point at. `relay.vertexlab.io` needs NIP-42 AUTH, which the core does not
speak; `relay.nostr.band` is dead.

### Who reaches the public indexers

Only the app host, by default. `SonarClient::connect` and `connect_in_memory`
use `RelayRoutesConfig::disabled()` — tests and tools never touch a relay they
were not given. `sonar-ffi` passes `public()`, and `sonar-cli` is opt-in
(unset = disabled). Both read `SONAR_LOOKUP_RELAYS` from the process
environment: `none` or empty = off, `public` = the public set, a comma list =
those relays as a local directory. The iOS QA driver launches the app with
`none`, `scripts/qa/peers.sh` exports `none` for its peers, and the public set
is dropped entirely when any of our own relays is a loopback/private address
(a dev build pointed at a local relay). Known gap: Android emulator QA runs
get no environment, so a fresh app build under `android-smoke.sh` publishes
its throwaway identity's lists (tracked in #627).

### State on disk

`<db>.sonar-relay-records.json`: what was last distributed per kind, and the
relays of an adopted list. In `sidecar_paths`, so wipe and reset remove it.

## Not in this change (parked)

Finding *other* accounts through their lists — KeyPackage and profile lookups
on their relays, welcome routing to their inbox, group relays built from
members' write relays — is parked on #628 with follow-ups in #627. Its payoff
is gated on the MDK upgrade that lets non-Sonar Marmot clients talk to Sonar
at all.

## Tests

- Unit (`relay_routes::tests`, `pool_tests`): list parsing, the decision
  table, defaults, the absence quorum, NIP-01 tie-break, stamping, the local
  relay guard, sidecar round trip, route-relay reuse and overlapping use.
- e2e (`tests/e2e.rs`, `relay_routes` module): an outbox client finds the
  account through the lookup relay alone; an imported account's lists are kept
  and adopted; nothing is published when no lookup relay answers; deferred
  without a quorum; no republish inside the interval and an unchanged
  rebroadcast after; a pass that reached no indexer is retried; the profile is
  not published over one the lookup could not read.
- QA registry: QA-137 … QA-140.
