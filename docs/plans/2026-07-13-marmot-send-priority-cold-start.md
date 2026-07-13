# Plan: marmot-send-priority-cold-start

**Goal:** Make Marmot/internet sends feel instant and production-ready by prioritizing user sends over cold-start catch-up, without breaking MLS group integrity, with clear UX delivery states.

## Why
PR #220 device logs showed multi-second (often ~10–20s) send lag after launch with BLE off. Root cause: cold-start Marmot backlog — live subs for all groups, 1024-event buffer overflow (drop 512), and 16-group historical catch-up competing with outbox publish.

## Phases

### P0 — Send priority + thin live tail + observability
- Defer historical catch-up while `send_inflight > 0`
- Thin live kind-445 `since` to max(watermark−overlap, now−30m)
- Log `send_local_pending` / `send_publish_start` / `send_first_ack(rtt_ms)` / `send_publish_failed`
- Snapshot: `send_inflight`, `buffer_drops_total`, `catchup_queue_len`
- **MLS-safe:** publish is network-only; live drain still processes commits

### P1 — Smarter live buffers
- Split giftwrap vs group live buffers (512 / 768)
- One flood cannot wipe the other
- Shared half-drop helper

### P2 — Active-chat catch-up + resub churn control
- `prefer_catchup_group(nostr_group_id_hex)` so open chat is repaired first
- Rate-limit `ensure_subscriptions` resubscribes (≥20s)
- Wire host: iOS opens DM → prefer that group

### P3 — Benchmarks
- Pure helper microbench (catch-up prefer + live since)
- Device validation via `send_first_ack rtt_ms`

## UX outcomes
| State | User sees |
|-------|-----------|
| Local persist | Bubble appears immediately as **Sending** |
| First relay OK | **Sent · internet** (first-ack) |
| Cold start | History fills in background; send not blocked |
| Failure | **Couldn't send** (retryable outbox) |

## Test plan
- Unit: live_group_since, split buffers, prefer catch-up, P3 cheapness
- Full sonar-core lib suite
- Persistence: local_first_send_persists_pending_message_before_relay_publish
- Device: BLE off, Marmot chat, measure send_first_ack

## Status
- Core P0–P3: `72843b0c`
- This ship: plan doc + FFI/iOS prefer hook + review


## Review fix
- Hosts pass MLS group id into prefer_catchup_group; core maps MLS to nostr #h id used by the catch-up queue.

- Compose preferCatchupGroup on openChat/openDm for Android/desktop parity.
