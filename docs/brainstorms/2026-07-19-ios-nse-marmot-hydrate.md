# Plan: iOS NSE Marmot hydrate (match White Noise + Signal)

**Branch:** `feat/ios-nse-marmot-hydrate`  
**Goal:** After force-quit, a Transponder chat push leaves decrypted messages in the shared local DB and decorates the notification from that state — same shape as White Noise iOS and Signal-iOS.

## Reference shapes

| | White Noise iOS | Signal-iOS | Sonar (this plan) |
| --- | --- | --- | --- |
| Wake | Generic APNS + `mutable-content` | Generic APNS + `mutable-content` | Unchanged Transponder `nse_prototype_alert` |
| Process | Single NSE opens App Group Marmot, `collectNotificationsAfterWake` (~8s), decorate | NSE opens shared GRDB, fetch/process, badge/local notifs | Single NSE: Transponder → Marmot wake; Breez → existing SDK path (lazy, never both) |
| Store | App Group only (fail if missing) | App Group + Keychain | Migrate `sonar-marmot/` → App Group; share Keychain access group |
| Cursor | `cursorPersistence: .frozen` on NSE | N/A (server fetch ack model) | `CursorPersistence::Frozen` — do not advance durable sync watermark on NSE wake |
| Open app | Local-first paint | Local-first paint | Unchanged `openDM` / local summaries |

## Constraints

- One NSE per app (Apple): keep Breez + Marmot in `SonarNotificationService`, **lazy-init one path per wake**.
- APNS stays plaintext-free (no group/message body in provider payload).
- Account Key Durability: never mint a new `marmot-nsec` / DB key from the NSE on miss — hard-fail → generic banner.
- Signal-local-first: main app still paints from DB first; NSE hydrate is best-effort within ~8–25s.
- Cross-platform: Android already syncs-on-push; document parity. No Android regress.
- Do not link Tor/Arti into the NSE path; relay clearnet only (same as WN seed relays).

## Phases

### P0 — Shared storage (foundation)

1. Add `Shared`-style config (or `MarmotAppGroupStore`) resolving App Group `group.sh.hedwig.sonar` → `sonar-marmot/marmot.sqlite`.
2. One-time migrate from Application Support `sonar-marmot/` into App Group (copy DB + sidecars + sync/outbox/index blobs next to DB).
3. Pin protection `.completeUntilFirstUserAuthentication` (already done for SIGBUS).
4. NSE + app entitlements: `keychain-access-groups` = `$(AppIdentifierPrefix)sh.hedwig.sonar` (or the group the app already uses for identity items). Ensure `marmot-nsec` and `marmot-db-key` are readable from NSE after first unlock.
5. Wipe/reset paths clear App Group Marmot root + Keychain (Account Key Durability / wipe completeness).

### P1 — Core wake API (WN `collectNotificationsAfterWake`)

1. `CursorPersistence { Durable, Frozen }` on connect (or a dedicated `SonarNode.connectForPushWake(...)`).
2. When Frozen: message decrypt/persist + drain still run; **`advance_sync_watermark` does not persist**.
3. FFI: `collectNotificationsAfterWake(maxWaitMs) -> [DrainNotificationInfo]` = connect relays → bounded `sync_force` → `drain_pending` → shutdown-friendly.
4. Unit tests: frozen wake persists messages but leaves watermark unchanged; durable path still advances.

### P2 — NSE Transponder path (Signal/WN decorate)

1. Link `SonarCore` into `SonarNotificationService` (no Tor package on NSE target).
2. On Transponder push: read nsec + db key from Keychain; open App Group DB; `collectNotificationsAfterWake(8000)`; decorate primary alert via existing notification envelope/router; post additional local notifications for extras (cap like WN `maxAdditionalPresentations`).
3. On timeout/failure: keep generic fallback (never blank).
4. Honor `sonar.notifications.enabled` + mute prefs from App Group (already mirrored).
5. Set `sonarConversationId` on decorated content for tap handoff.
6. Breez path unchanged; do not start Marmot on Breez wakes.

### P3 — Main-app handoff + prefs

1. `SonarPushProcessor` titled locals must pass `sonarConversationId` (Android parity).
2. Cold open: local paint first; if NSE already wrote rows, no wait. Background `syncForce` still runs for residual gap (watermark may be behind after frozen wakes — intentional).

### P4 — Measurement + Android note

1. Manual / harness: force-quit → Transponder DM → confirm titled banner + message in DB before foreground; cold open `t0→t1` then message visible without waiting full `t2→t4`.
2. RSS spike log in NSE (Signal-style memory log in DEBUG).
3. Short Android force-stop/FCM note in plan follow-up.

## Memory strategy

- Binary will grow: Breez (~24MB today) + sonarffi. Peak RSS mitigated by **never initializing both SDKs in one wake**.
- NSE build should use messaging-oriented SonarCore (no `calls-audio` feature if that shrinks the staticlib for a future NSE-specific slice). First ship may share the app’s `sonarffi` and accept a device RSS spike gate.
- If jetsam on mid-tier phones: fall back to decorate-from-partial-drain + G2 open-path SLA; do not advance watermark on killed wakes.

## Non-goals (this PR series)

- Putting plaintext in Transponder payloads.
- Separate second NSE target (impossible).
- Desktop offline push.
- Full Tor in NSE.

## Success criteria

- Kill app ≥6h, receive Transponder DM: notification shows local title/body when hydrate succeeds; message visible in chat on cold open from local DB without waiting on full foreground sync.
- Hydrate miss: generic banner; open no worse than today (background catch-up).
- No new account key on NSE Keychain miss.
- R-004 notification dedup + R-005 per-chat watermark tests stay green.
- Breez offline BOLT12 NSE path still works.

## Sequencing

Ship as stacked PRs if needed: **P0 → P1 → P2+P3 → P4**. Do not land App Group move without wipe coverage and migration tests.

## Android parity note

Android already hydrates on push via `SonarPushProcessingService` → `syncForce()`
into the local DB before/with the notification. This iOS change closes the
force-quit gap to that shape. No Android behavior change in this PR.

