---
title: Trill (nudge) — an MSN-style attention signal that respects privacy and abuse resistance
cat: Engineering
date: 2026-07-25
summary: A nudge shakes the screen, fires a haptic, and plays a bell — but unlike MSN Messenger's notorious feature, Sonar's trill is persisted, muted, and throttled so attention never becomes harassment.
author: The Sonar team
read: 7 min read
feature: false
---
# Trill (nudge) — an MSN-style attention signal that respects privacy and abuse resistance

In 2005, MSN Messenger shipped a feature that became equal parts beloved and notorious: the "nudge." One button press shook the recipient's entire window, fired a sound, and demanded attention. It was pure, unfiltered presence — and it was a harassment vector. Users could spam it, couldn't silence it without blocking the sender entirely, and the loop closed with both parties nudging each other into a cacophony.

Sonar 3.6 brings the nudge back as **Trill** — but this time, the architecture is privacy-preserving, the abuse guards are concrete, and the signal is persisted instead of ephemeral. Here is how we rebuilt a classic feature for a messenger that folds Bluetooth mesh and Tor-hidden internet paths into one conversation.

## The rule: a trill is a message, not a hack

The original MSN nudge was a side-channel. It did not persist in chat history, and you could not look back and see who had nudged you when. Sonar's design brief rejected that shape immediately: a nudge that vanishes is a nudge you cannot audit.

A trill in Sonar is a **real message**. It rides the same send pipeline as a text message, it wakes the recipient's device via push, and it renders as a centered system row that stays in the transcript forever. The wire format is a reserved control line in the same idiom as payments and call signaling — the ⚡ lightning bolt prefix, a version field locked at 1, and a sender-generated token:

```
⚡TRILL|1|<id>
```

That line travels on both transport legs:

- **Marmot (internet):** ordinary kind-9 application message via Tor-hidden relays
- **Mesh (nearby):** encrypted private-message payload over BLE

Core classifies it as `NotificationKind::Trill` (`notification.rs`) and both hosts pick up the distinct sound. The version field is locked at 1 — parsers reject any other version so a future v2 degrades to plain text on old clients instead of mis-rendering. The sender-generated token lets the same trill be recognized if it arrives on both legs (mesh and Marmot) and provides the key for receiver-side throttling.

This is the shape that gives us everything else for free: offline delivery, push wakeup, dedup, echo reconcile, and cross-leg folding. No new wire format, no new UniFFI callback, no new noise payload byte. The persisted row is not an add-on; it is the primitive.

## What a trill feels like

When the app is foregrounded and a trill arrives, three things fire together:

- **Shake:** `data-shake="1"` set on the app root, removed after **620 ms**. The choreography (from the Claude Design prototype) translates ±7-9 px with ±1° rotation using a cubic-bezier curve — a physical shake, not a jitter.
- **Bell:** two identical sine tones **160 ms apart**. Each sweeps exponentially from 880 Hz to 660 Hz over 120 ms with a gain envelope that attacks over 20 ms and decays to 240 ms. Total bell ≈ 400 ms. On device this is a bundled `sonar_trill` asset, not a synthesized tone.
- **Haptic:** `navigator.vibrate([40, 60, 40])` — buzz 40 ms, pause 60 ms, buzz 40 ms. Maps to `VibrationEffect.createWaveform` on Android and a two-pulse `UIImpactFeedbackGenerator(.medium)` sequence on iOS.

If the app is backgrounded — or fully killed on iOS — the trill still arrives as a normal notification with the distinct sound. The APNs payload itself is opaque, but the Notification Service Extension opens the shared encrypted chat database, decrypts locally, and classifies the content before the banner is presented: a killed-app trill shows the nudged-you banner with the trill sound, and the raw wire line never appears. If local decryption is unavailable (the store is busy, or the extension runs out of time), the banner falls back to the generic placeholder. Muted chats stay silent on this path too, once the app has launched at least once on the new build (that first launch is what mirrors your existing mutes to the extension).

## The rendering: centered row, chat-list preview

The transcript renders a trill as a centered pill row (`NudgeMsg` / `.bc-nudgemsg`) with an accent-soft background, a wiggle-on-appear bell icon, and context-aware text:

- Yours: `You sent a nudge`
- Theirs (DM): `<peer> nudged you — 👋`
- Theirs (group): `<author> nudged you — 👋`

The chat-list preview is simply `Nudge`. No raw `⚡TRILL|1|<id>` line ever appears in the UI — that is a wire format detail, not a human-facing string.

## Abuse resistance: why this is not 2005

MSN's nudge was a harassment vector because it had **no guards**. You could fire it as fast as you could click, the recipient could not silence it without blocking the sender entirely, and there was no way to look back and see what had happened. Sonar's design brief called this out as a blocking concern before a single line of code was written.

The shipped guards are concrete and client-enforced:

| Guard | Window | What it stops |
| --- | --- | --- |
| **Sender cooldown** | 8 s per chat | Button is disabled after send; monotonic clock, in-memory |
| **Receiver alert throttle** | 8 s per chat | At most one `buzz()`/notification per window; excess trills still write rows |

The sender cooldown is honored by the UI. The receiver throttle is enforced by the recipient — clients cannot be trusted to honor limits, so the receiver runs its own independent window. Excess trills in either direction still write the persisted row; only the alert is suppressed. The row is what rescues this from being harassment: attention is *deferred*, not denied. You open the chat later and see exactly who nudged you and when.

## Per-chat mute: the companion feature

The design brief discovered a critical gap: Sonar had **no per-chat mute**. Zero hits for `isMuted`/`muteChat`/`mutedUntil` across `apps/sonar/` and `ios/`. The only suppression concept was *block* — which drops the peer wholesale. A trill that cannot be silenced is exactly what made MSN's version abusive.

So per-chat mute ships alongside trill. It is a **general, not trill-specific** feature — Signal-style durations (1 hour, 8 hours, 1 day, 1 week, always) surfaced in three places (HomeScreen, DMScreen, SettingsScreen) with a bell-off icon replacing the unread dot on muted rows. Mute suppresses sound/haptic/shake/**and notification** for **all** message kinds in the chat, not only trills. Rows and unread badges still accrue.

The invariant is simple: **a trill never produces less than a persisted row, and never more than the chat's notification level already allows.**

| State | Trill behavior |
| --- | --- |
| Blocked peer | Dropped at ingest. No row, no alert. |
| Muted chat | Row + unread badge only. No shake/bell/haptic/notification. |
| OS silent / DND | Row + notification; OS decides presentation. |
| Foreground | Row + shake + bell + haptic. |
| Background | Row + notification with trill sound. |

Mute wins over trill. That is the correct security decision: explicit per-chat user intent should not be bypassable by a signal whose stated purpose is "break through inattention." If trill could punch through mute, mute would become useless and users would reach for **block** instead — which is invisible and permanent. The persisted row is what makes this tradeoff liveable.

## Why a nudge belongs in a private messenger

A private messenger is also a **presence-aware** messenger. Sonar folds Bluetooth mesh and Tor-hidden internet paths into one conversation; the bubble color tells you whether the message traveled cyan (nearby) or indigo (far). That presence is not a tech demo — it is the context in which communication happens.

A trill is a signal that says "I am here and I want your attention." On the mesh, that means "I am in this room with you." Over the internet, it means "I am thinking of you right now." In both cases, the signal is **deferred**, not synchronous — it writes a row that you see when you open the chat, not a blocking popup that demands you respond immediately. That is the right shape for an attention signal in 2026.

The persisted row is what makes it auditable. The cooldown and throttle are what make it non-abusable. The per-chat mute is what makes it respect user intent. And the wire format — a real message on both transport legs — is what makes it work in a messenger that folds networks instead of splitting people.

## The shipped scope

PR #336 ships the full vertical slice across core, Android, iOS, and Compose Desktop:

- Core prefix + classification in `notification.rs`
- Suppression call sites (preview, recency, resync-floor)
- `SonarTrill.kt` / `SonarTrill.swift` codec pair
- Per-chat mute with Signal-style durations
- Android haptic abstraction + `sonar_trill` sound
- iOS haptic + sound + `NotificationService` classification
- Compose Desktop shared UI (mute, nudge send/receive, tray notification; in-app buzz is a documented no-op on JVM)
- Sender cooldown + receiver alert throttle
- Shake + bell + haptic on receive
- Persisted system row rendering

Known gaps called out in the wire spec:

- iOS killed-app distinct sound (NSE cannot decrypt to classify yet)
- Mute does not sync across linked devices (tracked gap, Signal syncs it)
- Compose Desktop in-app buzz (no haptic hardware)
- Old clients render raw `⚡TRILL|1|<id>` as text (same forward-compat wart as `⚡PAY`)

## Closing

The MSN nudge was a feature out of time. It shipped before abuse resistance was a first-class design concern, before per-chat silencing was standard, and before "persisted row" meant anything in a messenger context. Trill is what happens when you rebuild it with those constraints in mind.

It shakes the screen. It fires a haptic. It plays a bell. But unlike 2005, the row stays, the guards are concrete, and the signal never outruns the user's right to silence. That is the balance Sonar strikes: presence without harassment, attention without abuse.

---

*Sonar is free and open source. [Read the docs](Sonar%20Docs.html) or [get the app](Sonar%20Landing.html).*
