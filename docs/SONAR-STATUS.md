# Sonar status over Nostr

How Sonar publishes and displays system status without a proprietary status host.

## Pipeline

```text
┌──────────────────┐     kind 30078      ┌─────────────────┐
│  sonar-status    │  d=sonar-status     │  Public relays  │
│  probe + sign    │ ─────────────────►  │  damus/nos/…    │
└──────────────────┘     (signed event)  └────────┬────────┘
                                                  │ REQ
                                                  ▼
                                         ┌─────────────────┐
                                         │  web /status    │
                                         │  status-nostr.js│
                                         └─────────────────┘
```

1. **`sonar-status`** (Rust binary in `core/sonar-status`) probes relays (and
   optional HTTP health URLs), builds a JSON document, signs a replaceable
   Nostr event, and publishes it.
2. **Website** `/status` paints seed data immediately, then (if
   `STATUS_PUBKEY_HEX` is set) REQs the latest event and merges services /
   incidents / optional relay list.
3. **Browser** still measures live WebSocket RTT to the relay list for the
   “Relay network” section (visitor-local latency).

## Event format

| Field | Value |
| --- | --- |
| `kind` | `30078` |
| tag `d` | `sonar-status` |
| tag `client` | `sonar-status` (optional, set by publisher) |
| `content` | UTF-8 JSON (see below) |
| `pubkey` | Ops status key — must equal site `STATUS_PUBKEY_HEX` |

### Content JSON (website schema)

```json
{
  "services": [
    {
      "id": "dm",
      "name": "Encrypted DMs (Marmot)",
      "desc": "End-to-end encrypted direct messages",
      "uptime": 99.95,
      "state": "degraded"
    }
  ],
  "relays": [
    { "url": "wss://relay.damus.io", "region": "Global · CDN" }
  ],
  "incidents": [
    {
      "date": "Jul 13, 2026",
      "title": "Probe detected degraded performance",
      "level": "degraded",
      "updates": [
        { "t": "15:04 UTC", "s": "Investigating", "b": "…" }
      ]
    }
  ]
}
```

Rules enforced by `web/src/lib/status-nostr.js`:

- `services[].id` — `^[A-Za-z0-9._-]{1,40}$`
- `state` — omit or `ok` | `degraded` | `down` (omit/`ok` = operational)
- `uptime` — number 0…100
- `incidents[].level` — `degraded` | `maintenance` | `down`
- `updates[].s` — `Investigating` | `Identified` | `Monitoring` | `Resolved` | `Completed`
- `relays[].url` — `wss:` only
- max content size 64 KiB

Operator-only fields (`updated_at`, `probe`) may appear in local `--out` files
but are **stripped** from the published event content by `sonar-status`.

## Constants (keep in sync)

| Location | Symbols |
| --- | --- |
| `core/sonar-status/src/main.rs` | `STATUS_EVENT_KIND`, `STATUS_EVENT_D` |
| `web/src/lib/status-data.js` | `STATUS_EVENT_KIND`, `STATUS_EVENT_D`, `STATUS_PUBKEY_HEX`, `STATUS_NPUB`, `STATUS_FEED_RELAYS` |

## Operator runbook

1. Generate a dedicated status key (not a user chat nsec):

   ```bash
   # example: 32 random bytes as hex (or use any nsec1 wallet export)
   openssl rand -hex 32 > ~/.config/sonar/status.hex
   chmod 600 ~/.config/sonar/status.hex
   cargo run -p sonar-status --manifest-path core/Cargo.toml -- \
     identity --nsec-file ~/.config/sonar/status.hex
   ```

2. Put `pubkey_hex` / `npub` into `web/src/lib/status-data.js` and deploy the site.

3. Cron every 5–15 minutes:

   ```bash
   ./scripts/status/publish.sh
   ```

4. Open `/status/` — hero should switch from `seed data` to `status feed` once
   the event is visible on `STATUS_FEED_RELAYS`.

## Trust model

- Website filters by **author pubkey** + kind + `d`.
- v1 website does **not** verify schnorr (same limitation as the stickers page).
  Publishing still signs correctly; a future web crypto verify is a follow-up.
- Anyone who steals the status nsec can publish false status — protect the file.

## Related code

- Publisher: `core/sonar-status/`
- Website reader: `web/src/lib/status-nostr.js`
- Website UI: `web/src/routes/status/+page.svelte`
- Seed fallback: `web/src/lib/status-data.js`

## Client bootstrap relays (status "Relay network")

The status page and `sonar-status` probe the **same default relay set Sonar apps
connect to**, not an arbitrary marketing list:

| Relay | Source |
| --- | --- |
| `wss://relay.damus.io` | iOS + Android + CLI |
| `wss://nos.lol` | iOS + Android + CLI |
| `wss://relay.primal.net` | iOS + Android + CLI |
| `wss://offchain.pub` | iOS `NostrRelayManager` |
| `wss://nostr21.com` | iOS `NostrRelayManager` |
| `wss://relay.kaleidoswap.com` | iOS + Android/JVM |
| `wss://nostr.relay.hedwig.sh` | Android/JVM (+ Hedwig) |

**Out of scope for this table:** geohash / location-channel relays from
`relays/online_relays_gps.csv` / `GeoRelayDirectory` — those are chosen
per-geohash at runtime and change with the user.

Keep these three places in sync when the app defaults change:

1. `ios/bitchat/Nostr/NostrRelayManager.swift` `defaultRelays`
2. `apps/sonar/.../SonarCore.android.kt` / `SonarCore.jvm.kt`
3. `web/src/lib/status-data.js` + `core/sonar-status` `DEFAULT_RELAYS`

## Seed vs live services

| Source | Services | Incidents | When |
| --- | --- | --- | --- |
| Website seed | Skeleton rows, all operational, **no mock outages** | **Empty** | First paint / feed unavailable |
| `sonar-status` probe | Only **measured** rows (`relays` + optional HTTP) | Auto from measured failures | Each publish |
| Future dedicated probes | Per-surface rows (DM, push, …) with real checks | Same | As probes land |

The website may still list the full product surface (DM, groups, …) as a
**skeleton** so the page layout matches the design. Those rows stay operational
until the feed supplies a measured `state` for the same `id`.

### Merge rule (website)

When a status event arrives:

1. Replace `incidents` entirely from the feed (seed has none).
2. For `services`: **upsert by `id`** — feed rows override seed rows with the
   same id; seed-only ids remain as operational placeholders until probed.
3. For `relays`: if the feed includes a non-empty list, use it (and re-ping);
   otherwise keep the client-default seed list.

Website merge is **upsert-by-id** via `mergeStatusPayload` in
`web/src/lib/status-data.js`.

## Real service probes (design)

Goal: every row on `/status` should eventually mean "we ran a check", not
"design mock uptime".

### Probe matrix

| Service id | Check (v1 target) | How `sonar-status` implements it | Auth / secrets |
| --- | --- | --- | --- |
| `relays` | WebSocket open RTT to client default relays | **Done** — `probe_relay_ws` | None |
| `dm` | KeyPackage publish + fetch own package from bootstrap relays via `sonar-core` | **Done** — `chat::probe_marmot_keypackage` (`--chat-probe`) | **Dedicated probe nsec** (`SONAR_STATUS_PROBE_NSEC`) — not the publisher key |
| `groups` | Create/send in durable probe MLS group (A→B or multi-member) | planned | Probe nsec(s) |
| `media` | Blossom reachability: HTTP HEAD `DEFAULT_BLOSSOM_SERVER` | **Done** | None |
| `stickers` | REQ kind 30031 on bootstrap relays, count visible packs | **Done** | None |
| `push` | HTTP GET transponder health (and optionally sandbox) | `--http` / `SONAR_STATUS_HTTP` | None if health is public |
| `payments` | HTTP GET Breez NDS / notify health if exposed; else mark `unknown` and omit row | `--http` | None |
| `calls` | Optional: connect Iroh relay / echo; else inherit signaling from `relays` + separate note | deferred | None |

### States

| State | Meaning |
| --- | --- |
| omit / `ok` | Check passed |
| `degraded` | Check passed slowly or partially (e.g. &lt;85% relays, high RTT, HTTP 429) |
| `down` | Check failed (timeout, HTTP 5xx, zero relays) |
| *absent from feed* | Not measured this run — website keeps skeleton operational |

Do **not** invent degraded product rows from relay latency alone. Relay trouble
is reported on `id: "relays"`; product rows appear only when their probe runs.

### Publishing cadence

- Cron every **5–15 minutes** (`scripts/status/publish.sh`).
- Keep `--previous` / state dir so incidents open/resolve instead of spamming.
- Publish relays must include at least one of `STATUS_FEED_RELAYS` on the site
  (include `wss://nostr.relay.hedwig.sh` when using Hedwig infra).

### Rollout steps

1. **Done:** client-default relays; empty seed incidents; measured `relays` (+ HTTP).
2. **Done:** website upsert-by-id merge (`mergeStatusPayload`).
3. **Done:** Marmot KeyPackage round-trip → service `dm` via `--chat-probe` +
   dedicated probe nsec (`core/sonar-status/src/chat.rs`).
4. **Next:** A→B text canary (two probe identities) for stronger E2E `dm` / `groups`.
5. **Next:** `probe_sticker_index` + Blossom HEAD (no chat identity).
6. **Optional:** store daily uptime samples to drive real 90-day bars (replace
   `syntheticHistory`).

### Local verify

```bash
# Probe only — should list relays (+ any --http), not mock DM outages
cargo run -p sonar-status --manifest-path core/Cargo.toml -- probe --pretty

# Dry-run publish
SONAR_STATUS_NSEC=… ./scripts/status/publish.sh --dry-run
```

