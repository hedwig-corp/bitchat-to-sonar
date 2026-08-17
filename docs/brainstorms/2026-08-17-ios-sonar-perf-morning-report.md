# Overnight iOS Sonar Perf — Morning Report

Device: iPhone 14 Pro Max (“Vincenzo’s iPhone”), ~280 Marmot groups.
Account preserved (in-place install only). Workspace: `hxph` worktree.

## Measured wins

| Issue | Before | After | Fix |
| --- | --- | --- | --- |
| Home after local model (`t1→t1b`) | **8.96 s** median | **~180 ms** median | R-039 revision `dmRows` + LazyVStack |
| Active → Home appear (`t0a→t1b`) | ~9.3 s | **~425–574 ms** | + `t0a_became_active` |
| Closed-chat rebuild fan-out | scales with visits | max 1 live rebuild | R-038 |
| Store invalidation budget | up to N×10 Hz | shared 100 ms | R-037 |
| Whole-history message scanners | all groups / publish | watermarked chats | R-040 |
| Adapter O(n) before host skip | array eq + index + map | revision snapshot | **R-041** |
| `@` mention keystroke fan-out | store `@Published` query | local `SNComposer` | **R-042** |
| Decoded thumbs / GIF reload | re-decode / every update | 48 MB LRU + fingerprint | **R-043** |
| Text row scroll cost | SwiftUI graph per cell appear | reused UIKit cell + pre-measured frames | **R-044** |

Latest installed Debug: **R-044** UIKit text rows (built + installed in place
2026-08-17 ~11:00). Previous: 9010 (R-041–R-043 Giulia/Android parity).

### Cold-start after R-041–R-043 (3 runs, 281 groups) — 2026-08-17 morning

| Phase | min | med | max (ms) |
| --- | ---: | ---: | ---: |
| t0 → t0a (iOS foreground delay) | 151 | 244 | 249 |
| t0a → t1 (active → local paint) | 242 | 244 | 410 |
| **t1 → t1b (model → Home appear)** | **181** | **181** | **194** |
| **t0a → t1b (active → Home)** | **423** | **425** | **604** |
| t0 → t4 (in-app → synced) | 2646 | 3932 | 5829 |

Home projection win held (still ~181 ms vs original 8.96 s). Relay path variance is network-bound, not a Home regression.

### Giulia baseline (pre R-041–R-043, from applog)

- `chat_open` retained `present_ms`: 14–31
- `transcript_rebuild` while open: `conversations=1`, max_ms typically 4–20
- No `transcript_apply` / `media_decode` markers yet (added in 9010)

## Giulia / Android parity (R-041–R-043) — shipped

1. **R-041** — `SNConversationRenderState` + revision-only adapter sync; `SONAR_BENCH transcript_apply skip|apply`
2. **R-042** — removed `composerMentionQuery`; roster always passed; suggestions from draft locally
3. **R-043** — `SNDecodedMediaCache` (48 MB), wipe/memory clear; GIF WKWebView reload fingerprint; `media_decode` / `gif_reload` markers

Ledger: `scripts/check-regression-ledger.sh` OK. TranscriptEngine: 18 tests passed.

## Scroll feel — Signal `CVCell` parity (R-044) — shipped

Reported after 9010: everything felt fine except scrolling. The remaining gap was
structural rather than a hot marker, and all three parts are things Signal does
off the scroll path:

1. **Measure inside the layout pass.** `sizeForItemAt` built a height key that
   embedded the whole message text, then measured misses with
   `UIHostingController.sizeThatFits`. `UICollectionViewFlowLayout.prepare()`
   sizes every loaded row, and `TranscriptRowHeightCache` dropped *all* heights
   on any width change. Signal precomputes `CVCellMeasurement` in `CVLoader` and
   its layout only reads sizes.
2. **A SwiftUI graph per cell appearance.** `UIHostingConfiguration { row }` with
   an `if/else` row body (`_ConditionalContent`) cannot reuse a hosting view
   across neighbouring rows of different kinds. Signal's `CVCell` assigns values
   into a reused `CVComponentView` tree.
3. **No prefetch.** First decode/measure happened when the row was already
   on screen.

Shipped: `SNTextBubbleModel` (paint state derived once per `(id, height key)`),
`SNTextBubbleLayout` (pure geometry, shared by measure and `layoutSubviews`),
`SNTextBubbleMeasurementCache` (600-entry `(key, width, direction)` LRU),
`SNTextBubbleCell` (author, quote chip, attributed text with link/mention
hit-testing, inline time + transport icon, show-more, state footer with retry,
swipe-to-reply with haptic, context menu with lifted bubble preview, VoiceOver
custom actions), a `TranscriptEngine` `registerCells`/`provideCell` seam so one
transcript can mix UIKit and hosted rows, and hashed height keys.

Rich rows (media, sticker, pay, call, nudge, action) stay on the hosting path —
`SNTextBubbleModel.handles` is the fork. Fallback without a rebuild:
`SONAR_UIKIT_BUBBLES=0` or `defaults write … sonar.uikitTextBubbles false`.

Height parity with the hosted row it replaces is exact (delta 0 on the three
sampled shapes), pinned by
`SNTextBubbleLayoutTests.heightStaysCloseToTheSwiftUIRow` at ±2 pt tolerance.
Tests: 12 passed on iPhone 16 Pro sim. Still owed: subjective scroll check on
device, and an `Animation Hitches` Instruments capture on Giulia if it still
does not feel right.

## Deferred (cold Home follow-up, not Giulia)

4. Concurrentize `loadLocalSummaries` sequential awaits
5. Signal CLVLoader-style `@Published` home row models

## Keep tracing (post-impl loop)

Markers (Debug / applog):

| Marker | Meaning |
| --- | --- |
| `t0` / `t0a` / `t1` / `t1b` | Cold Home phases |
| `chat_open` | Navigation present latency |
| `transcript_rebuild` | Rebuild cost while chat open (`conversations=` should stay 1) |
| `transcript_apply` | Host skip vs apply after R-041 |
| `message_scan marmot needing=` | R-040 watermark gate |
| `media_decode hit\|miss` | R-043 LRU |
| `gif_reload load\|skipped` | GIF fingerprint guard |

Re-run whenever conversation / transcript / composer / media code changes:

```sh
# Cold Home
UDID=43798F9E-FC16-5D02-A0F2-51ACF9C166B9 RUNS=3 TIMEOUT=25 CAPTURE=applog \
  OUT=/tmp/sonar-bench/morning-home scripts/bench/device-bench.sh

# Giulia manual: open → type → @ → scroll media, then pull log:
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier sh.hedwig.sonar \
  --source "Library/Application Support/sonar-marmot/logs/ios/sonar-ios.log" \
  --destination /tmp/sonar-bench/giulia-latest.log
rg 'SONAR_BENCH (chat_open|transcript_|message_scan|media_decode|gif_reload)' /tmp/sonar-bench/giulia-latest.log | tail -40
```

Append new medians to this file. Prefer `CAPTURE=applog`. Never uninstall.

## Subjective check still owed on 9010

Open Giulia on device: type plain + `@…`, scroll through images/GIFs. Confirm feel vs Android and that `transcript_apply` shows skip≫apply while typing unchanged history.
