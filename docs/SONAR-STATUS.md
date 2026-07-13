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
