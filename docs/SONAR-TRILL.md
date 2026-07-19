# Sonar Trill (Nudge)

MSN-Messenger-style attention signal ("trillo"). A trill is a **persisted
message** whose content is a reserved control line, following the same idiom as
`⚡PAY` (docs/SONAR-PAYMENTS.md) and `☎CALL` (core/sonar-core/src/call/signaling.rs).

## Wire format

```
⚡TRILL|1|<id>
```

- `⚡TRILL` — literal prefix (U+26A1 + "TRILL").
- `1` — version, locked. Parsers MUST reject any other version so future
  versions degrade to plain text on old clients instead of mis-rendering.
- `<id>` — sender-generated token, 1-64 bytes of `[0-9a-fA-F-]` (hex-or-dash,
  same shape as `⚡PAY` ids). Used to recognise the same trill if it arrives on
  both the mesh and Marmot legs, and for receiver-side alert throttling.
- No trailing fields. `⚡TRILL|1|abc|extra` is NOT a trill line.

Canonical parser: `parse_trill_line` in `core/sonar-core/src/notification.rs`.
Classification: `classify_content` returns `NotificationKind::Trill`.

## Transport

No new wire format. The line rides the normal message paths:

- **Marmot leg**: ordinary kind-9 application message via the existing send
  pipeline (local echo, outbox, background publish, push wakeup).
- **Mesh leg**: ordinary encrypted private-message payload (like `⚡PAY`).

Unlike reactions (`⚡REACT`, unmerged), a trill is a real conversation event:
it **does** bump recency, count as unread, advance resync watermarks, and
produce a push wakeup. Only rendering and notification classification differ
from a plain text message.

## Rendering (design: Claude Design project `c6936a45`, sonar/components.jsx)

Centered pill row (`NudgeMsg` / `.bc-nudgemsg`): accent-soft background, nudge
bell icon (wiggle animation on appear), text:

- mine: `You sent a nudge`
- theirs (DM): `<peer> nudged you — 👋`
- theirs (group): `<author> nudged you — 👋`

Chat-list preview text: `Nudge`.

## Receive effect (design: sonar/app.jsx `buzz()`)

Fired together when the app is foregrounded (any screen):

- **Shake**: whole-app viewport shake, 620 ms, `bcShake` choreography
  (translate ±7-9 px with ±1deg rotation, cubic-bezier(.36,.07,.19,.97)).
- **Bell**: two identical tones 160 ms apart; each a sine sweep 880→660 Hz over
  120 ms, ~240 ms long. On device this is the bundled `sonar_trill` sound asset.
- **Haptic**: pattern `[40ms buzz, 60ms pause, 40ms buzz]`.

Backgrounded/killed: a normal notification with the distinct trill sound via
`NotificationKind::Trill`. No DND/critical-alert bypass.

Honor the platform reduce-motion setting: skip the shake (keep sound/haptic)
when reduced motion is enabled, mirroring the design's
`prefers-reduced-motion` rule.

## Silence semantics

Invariant: **a trill never produces less than a persisted row, and never more
than the chat's notification level already allows.**

| State | Behaviour |
|---|---|
| Blocked peer | Dropped at ingest. No row, no alert. |
| Muted chat | Row + unread badge only. No shake/bell/haptic/notification. |
| OS DND / silent | Row + notification; the OS decides presentation. |
| Foreground | Row + shake + bell + haptic. |
| Background/killed | Row + notification with trill sound. |

## Abuse guards

- **Sender cooldown**: the nudge action is disabled for 8 s per chat after
  sending (MSN's own guard).
- **Receiver alert throttle**: at most one `buzz()`/notification per chat per
  8 s window; excess trills still persist as rows but alert silently. Client
  cooldowns cannot be trusted — the receiver enforces its own window.

## Per-chat mute (shipped with trill; general, not trill-specific)

Design: `MuteSheet` (sonar/components.jsx) with durations 1 hour, 8 hours,
1 day, 1 week, until-turned-back-on. Reached from long-press on the chat row
and from the DM/group screen. Muted rows show a bell-off icon in place of the
unread dot. Mute state is **local to the install** (not synced across linked
devices — tracked gap, Signal syncs it).

Mute suppresses notification/sound/haptic/shake for ALL message kinds in the
chat, not only trills. Rows and unread badges still accrue.

## UI entry point

Composer "+" action sheet (design: sonar/screens.jsx):

- DM: `Nudge — Buzz <peer>'s screen to get their attention`
- Group: `Nudge — Buzz everyone to get their attention`

Public geohash channels have no nudge action.

## Known gaps

- **iOS killed-app distinct sound**: the Transponder push payload is opaque to
  the NSE (`ios/SonarNotificationService/NotificationService.swift`), which
  cannot decrypt to classify. A killed-app trill therefore presents as the
  generic "New Sonar message" notification. Foreground and background-drain
  paths do classify and use the trill sound. Follow-up: NSE-side classification
  once the payload carries a category marker.
- Mute does not sync across linked devices (see above).
- Old clients render the raw `⚡TRILL|1|<id>` line as text — same accepted
  wart as `⚡PAY` before it shipped.
