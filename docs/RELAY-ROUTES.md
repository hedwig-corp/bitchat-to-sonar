# Relay routes: being found, and finding peers, without sharing a relay

Tracking issue: #626. Code: `core/sonar-core/src/relay_routes.rs`, wired into
`client.rs`. Both apps get it through the core; there is no host UI in v1.

## The problem

Sonar's Marmot pool is five hardcoded relays. Before #626 every publish and
every lookup went there and nowhere else: no kind `10002` (NIP-65 outbox
list), no kind `10050` (NIP-17 inbox list), nothing on the public indexer
relays other clients read. Anyone not sitting on one of those five relays
could not find a Sonar profile or KeyPackage, and Sonar could not find theirs.
White Noise sends welcomes only to the recipient's `10050` and has no
fallback, so a White Noise user could not invite a Sonar user at all.

## What the core does now

Two relay pools, on purpose:

| Pool | Relays | Used for |
|---|---|---|
| Marmot pool (`SonarClient::nostr`) | the five configured relays | everything it did before: subscriptions, sync, sends, KeyPackage, profile |
| Route pool (`RelayRouter`) | indexers, peers' relays, foreign group relays; connected on demand | lookups, record copies, welcome routing, group messages to foreign relays |

They never mix. nostr-sdk's pool-wide `send_event` reaches every WRITE relay
and `subscribe` every READ relay, and a targeted `send_event_to` refuses a
relay without WRITE, so an indexer in the Marmot pool would receive every
group message. `client::tests::lookup_relays_never_join_the_marmot_pool`
pins this.

### Our records (`RelayRouter::distribute_account_records`)

Runs in the background after every KeyPackage publish (i.e. on relay connect),
at most once per 24 h. For each of `10002`, `10050`, `10051` and kind `0` it
looks the current event up on our relays **and** the lookup set, then:

| Lookup outcome | Action |
|---|---|
| no lookup relay answered | publish **nothing**; retry next connect |
| nothing found, but some lookup relay was silent | **deferred**: publish nothing for that kind; retry next connect |
| nothing found and every lookup relay answered | publish Sonar's default, to our relays and the indexers |
| found (on any relay), names one of our relays | copy the existing signed event unchanged |
| found, does not name us (another client's list) | leave it alone; **adopt** it — the KeyPackage also goes to its write set |
| kind `0` found | copy it to the indexers that take profiles; never invent one |

"Nobody answered" is unknown, not absent, and so is "the relays that answered
had nothing": the one still holding the user's list may be the one that timed
out. Existence is evidence from a single relay; absence needs all of them.
Kinds `10002`/`10050` are replaceable: publishing defaults over an imported
account's real lists would replace them network-wide. A record counts as
distributed only when at least one relay accepted it, so a copy that reached
nothing is retried on the next pass instead of waiting out the interval; and a
pass with any lookup relay silent stamps nothing at all, so the next connect
looks again (the silent relay may hold a newer list than the one acted on).
Changing an adopted list needs the user's say-so (follow-up).

Defaults: `10002` = our relays, unmarked; `10050` = the Sonar relay plus two
others (NIP-17 keeps it small); `10051` = the write set, for clients that still
read the pre-2026-06 kind. Indexers are never written into the lists.

Indexers and what each accepts (checked 2026-09-28):

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

### Peers (`RelayRouter::resolve_peer_routes`)

One filter for the peer's `10002`/`10050`/`10051` on our relays plus the lookup
set, newest per kind, sanitized (TLS only, plaintext only on loopback), capped
(4 write, 4 read, 3 inbox), cached 6 h (15 min for a miss). Then:

- **KeyPackage:** our relays first (fast path, still the common case), then the
  peer's write set and legacy `10051` relays.
- **Profile:** our relays, then the peer's write set, then the lookup set.
- **Welcome:** our relays (the contextual hint the spec allows) **and** the
  peer's inbox set, or their read set when they have no `10050`. With an
  inbox list, one of its relays (ours or foreign) must accept the welcome or
  the send fails and the caller retries — a copy only on relays the peer never
  reads is a silent non-delivery. A peer with no lists gets what shipped
  before.
- **New group:** relays = ours, then each invitee's write relays interleaved,
  capped at 16, so every member's own relays are in the group's routing.
- **Group messages:** the outbox fan-out also publishes to the group's foreign
  relays, in the same first-ack race, so a member on a disjoint set receives
  what we send. Foreign group relays stay open between sends, bounded at 32
  across all groups with least-recently-used eviction.

### Configuration

`RelayRoutesConfig::public()` (the apps), `::disabled()` (in-memory sessions,
probes), `::local(relays)` (tests, private deployments: one directory relay
accepting every kind). `sonar-cli` reads `SONAR_LOOKUP_RELAYS`: unset = public,
empty or `none` = disabled, a comma list = local. QA harnesses with throwaway
identities should set it to `none`.

### State on disk

`<db>.sonar-relay-records.json` (what we last distributed per kind, adopted
relays) and `<db>.sonar-peer-routes.json` (the peer cache). Both are in
`sidecar_paths`, so wipe and reset remove them.

## Tests

- Unit: `relay_routes::tests` (parsing, caps, decision table, defaults,
  sidecars) and `relay_routes::pool_tests` (a route relay survives release).
- e2e (`tests/e2e.rs`, `relay_routes` module): disjoint relay sets complete a
  DM round trip; an imported account's lists are kept and adopted; nothing is
  published when no lookup relay answers; no republish inside the interval and
  an unchanged rebroadcast after; welcome fallback without a `10050`.
- QA registry: QA-137 … QA-141.

## Known gaps (tracked)

- **Receiving from foreign-only group relays.** Sync still reads kind `445`
  from the Marmot pool only. A group whose relays are all foreign (created by
  a White Noise client) is sent to, but not read from, until the route pool
  also subscribes to those relays. Blocked behind the MDK v0.10 bump anyway,
  since today's White Noise cannot invite a Sonar account.
- **Adding our relays to an adopted list** needs an approval step on both
  platforms.
- **Members added later** (`add_group_members`, invite links) do not extend
  the group's relay list; that needs an MLS extension update.
- **NIP-42 AUTH** for inbox relays that require it.
- **Geohash relays** still join the Marmot pool (#602 moves them out).
