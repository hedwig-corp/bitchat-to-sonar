# QA scenario registry

The checklist every agent QA pass runs (`.agents/skills/qa-pass/SKILL.md`),
and the place that pass writes back to. It only grows: each bug a pass finds
becomes a scenario here, so the next pass checks it by default.

## Rules

1. **Every bug found in a QA pass adds or extends a scenario** in the same PR
   that fixes it: the reproduction steps, what "good" looks like, and the
   finding id (`A10`, `i7`, …) under **Origin**.
2. **Automate what can be driven headlessly.** Prefer, in order: a unit/UI
   test at the real call site (named under **Guard**), then a scripted step in
   `scripts/qa/android-smoke.sh` (the scenario id is the function name), then
   manual steps. Mark which one applies under **How**.
3. **Keep ids stable.** Never renumber; retire a scenario by striking it
   through with the reason, so old QA reports still resolve.
4. **Both platforms.** Say which platforms a scenario covers. When only one
   platform can be driven, say why (Cross-Platform Feature Rule).
5. A bug that has now happened **twice** also gets a `docs/REGRESSIONS.md`
   entry — this registry is the checklist, the ledger is the invariant.

Peers are fresh `sonar-cli` identities from `scripts/qa/peers.sh`; "the app"
is the build under test on a dedicated QA emulator/simulator.

## Messaging

### QA-001 — First message in a new chat
- **Platforms:** Android (automated), iOS (manual)
- **Steps:** Search → paste a fresh peer's full npub → *Start secure chat* →
  type → Send.
- **Expect:** bubble reaches "Sent · internet"; the peer receives it within
  60 s; **the keyboard stays up** after the first send.
- **How:** `android-smoke.sh` QA-001 · Guard: `ChatTranscriptBodyComposerFocusUiTest`
- **Origin:** A10 (#616)

### QA-002 — Reply arrives in the open chat
- **Platforms:** both (Android automated)
- **Steps:** with QA-001's chat open, the peer sends a reply.
- **Expect:** visible within ~5 s of the peer's send (2 s measured
  2026-09-23), no reload flash, no duplicate bubble.
- **How:** `android-smoke.sh` QA-002

### QA-003 — Draft typed while the chat is pending survives
- **Platforms:** both (Android automated; iOS by unit test — the iOS pending
  window is ~2 s, too short to hit by hand)
- **Steps:** start a chat with a fresh npub and immediately type a draft; wait
  20 s (pending row reconciles to the real Marmot group); send.
- **Expect:** the draft is still in the composer, then delivered.
- **How:** `android-smoke.sh` QA-003 · Guard: `ComposerDraftsTest.pendingChatDraftFollowsTheChatToItsRealId`,
  `SNComposerDraftPersistTests.pendingChatDraftFollowsTheChatToItsRealId`
- **Origin:** A19 (#616)

### QA-004 — Inbound-first chat appears on the list
- **Platforms:** both (Android automated)
- **Steps:** app on the chat list; a fresh peer messages the app's npub.
- **Expect:** a new row with the message preview and an unread dot within 45 s;
  the dot is announced as "Unread" on that row.
- **How:** `android-smoke.sh` QA-004 (checks the "Unread" label sits on the new row)
- **Origin:** A29 (#616) — the dot had no label, so screen readers never
  announced unread chats and the smoke could not see it.

### QA-005 — Unread divider sits above the first unread message
- **Platforms:** both (Android automated)
- **Steps:** read a chat, leave it, receive TWO messages while on the list (or
  backgrounded), open the chat — also via the notification tap.
- **Expect:** read row < "Unread messages" < first unread < second unread, top
  to bottom: the divider is neither above a read row nor between unread rows.
- **How:** `android-smoke.sh` QA-005 (asserts that strict order; the
  notification-tap entry stays manual)
- **Origin:** A12 (#616) — seen once one row too high after a notification-tap
  open. Reproduced 3/3 on 2026-09-24 (#615 QA): the reopen painted the stale
  leave frame and the anchor froze on the read row — R-049, guarded by
  `TranscriptDisplayPolicyTest.reopenWithUnreadDoesNotRepaintTheLeaveFrame`.

### QA-006 — Quoted reply round trip
- **Platforms:** both (manual)
- **Steps:** long-press a message → Reply → type → send.
- **Expect:** Reply **focuses the composer** (keyboard up); the bubble shows the
  quote; the peer receives the reply.
- **Origin:** reply focus (#615)

### QA-007 — Partial npub offers no action
- **Platforms:** both (Android automated)
- **Steps:** Search → type the first 9 characters of an npub; then a complete npub.
- **Expect:** the prefix offers no *Start secure chat* and no *Join channel
  #npub1…*; the complete npub offers *Start secure chat*.
- **How:** `android-smoke.sh` QA-007 (both paths) · Guard: `SearchNpubGateTest`, `SearchNpubGateTests`
- **Origin:** A18 (#616)

### QA-008 — Search rows match the chat list
- **Platforms:** Compose (manual)
- **Steps:** Search → filter by an npub-only chat's shown title.
- **Expect:** the row has the same title and avatar as on Home; the mesh row
  reads "Nearby · Bluetooth".
- **Origin:** A13/A14/A8 (#616)

## Media

### QA-010 — Send a photo
- **Platforms:** both (manual)
- **Steps:** push a wide image into the gallery
  (`adb push x.png /sdcard/Pictures/` + media scan, or `xcrun simctl addmedia`),
  + → Send photo → pick → send.
- **Expect:** the "Uploading" bubble already has the image's aspect ratio and
  does not change size when it turns "Sent"; the peer receives the image.
- **Guard:** `ImageBoundsTest.pendingUploadEchoCarriesTheImageDimensions`, `MarmotMediaLocalEchoTests`
- **Origin:** A11 (#616). Note: the default Blossom server took ~36 s per
  upload on 2026-09-23 — report upload time separately from app time.

### QA-011 — Receive a photo
- **Platforms:** both (manual)
- **Steps:** `peers.sh send-image <peer> <app-npub> <file>`.
- **Expect:** renders within ~10 s at its own aspect ratio; opens full screen;
  no duplicate upload-progress rows (iOS #615).

### QA-012 — Video send strips location
- **Platforms:** both (manual on device; guards below)
- **Steps:** pick a video recorded with location on (fixtures:
  `apps/sonar/composeApp/src/jvmTest/resources/video/located.{mov,mp4}`,
  push them into the gallery), send it, and fetch it back with
  `sonar-cli fetch` on a peer.
- **Expect:** the received file carries no location (`udta`/`meta`/XMP) yet
  plays; an MP4/MOV that cannot be verified, or a WebM/MKV/AVI picked as a
  video, is refused (use *Send file*), never sent as-is.
- **Guard:** iOS `VideoLocationStripTests` (incl. `unreadableMetadataFailsClosed`);
  Compose `VideoPrivacyTest`, `VideoPrivacyFixtureTest`
- **Origin:** #615 (iOS) and its review (Compose parity, fail-closed)

## Notifications and lifecycle

### QA-020 — Background receive
- **Platforms:** both (manual)
- **Steps:** HOME; the peer sends; open the shade; tap the notification.
- **Expect:** a notification within ~10 s; the body respects the preview
  setting (off by default: "Open Sonar to read it."); the tap opens that chat
  with the divider per QA-005.

### QA-021 — No banner for the chat you are reading
- **Platforms:** iOS (manual, #615)
- **Expect:** a message for the open chat shows no NSE placeholder banner.

### QA-022 — Fresh onboarding: permissions wait for the account
- **Platforms:** Android (manual: `android-setup.sh --fresh`)
- **Expect:** no system permission dialog over the welcome/nickname/done
  steps; the sequence starts after *Start chatting*; the mic is also asked on
  first hold-to-record if it was denied.
- **Origin:** A1 (#616)

### QA-023 — Status bar legible
- **Platforms:** Android (manual)
- **Steps:** system light mode, app dark theme (default).
- **Expect:** clock/battery/signal icons are light and visible on every screen.
- **Origin:** A2 (#616)

## Home and channels

### QA-030 — "Around you" names the selected tier
- **Platforms:** both (location needed — emulator has one, iOS simulator
  needs `xcrun simctl location <udid> set <lat>,<lon>`)
- **Expect:** the card's title matches the highlighted tick and that tick is on
  screen; the card follows presence until the user picks a tier.
- **Guard:** `HereCardSelectionUiTest`
- **Origin:** A16 (#616)

### QA-031 — + sheet lists only working actions
- **Platforms:** both (manual)
- **Expect:** no row whose only effect is a "coming soon" toast.
- **Origin:** A17 (#616)

## Accessibility

### QA-040 — Icon controls are labelled
- **Platforms:** Android automated (`uiautomator dump` content-desc); iOS manual
  (VoiceOver / Accessibility Inspector)
- **Expect:** send, attach, emoji, voice, back, call, settings, start-chat, the
  nickname, search and composer fields all have spoken labels (`android-ui.sh
  dump` shows an unlabelled field as `E!` — uiautomator's NAF flag).
- **How:** `android-smoke.sh` QA-040 checks the chat screen (attach, emoji,
  send/record, back, composer field), home (settings, start-chat, nearby) and
  the search field. Manual: the nickname field (onboarding only, use
  `android-setup.sh --fresh`) and call buttons (call-capable peers only).
  Channel controls: QA-042. Guard: `IconButtonAccessibilityUiTest`
- **Origin:** A9/A5/A21 (#616)

### QA-041 — Profile QR is a real, scannable code
- **Platforms:** both (Android automated on macOS; iOS manual)
- **Steps:** Settings → profile card → screenshot the "Your key" card.
- **Expect:** the code decodes (any QR reader, or
  `swift scripts/qa/qr-decode.swift shot.png`) to the account's npub.
- **How:** `android-smoke.sh` QA-041
- **Origin:** A25 (#616) — Android drew the design mock's decorative pattern
  under "Let someone scan this to add you"; nothing could scan it.

### QA-043 — Accessibility sweep: no unlabelled controls
- **Platforms:** Android automated (`android-ui.sh naf` per screen); iOS manual
  (Accessibility Inspector audit)
- **Expect:** zero NAF nodes on home, search, start-chat, nearby, settings, a
  chat and its contact profile (extend the sweep when a screen is added).
- **How:** `android-smoke.sh` QA-043
- **Origin:** A28 (#616) — contact-profile action circles were NAF and their
  captions were dead taps; the 2026-09-24 sweep of every main screen is clean.

### QA-042 — Channel screen controls are labelled
- **Platforms:** Android (manual: open any location channel, `android-ui.sh dump`)
- **Expect:** back, bookmark ("toggle bookmark for #…"), Nearby, the composer
  ("Message <channel>") and Send are all labelled; no `E!` rows.
- **Origin:** A22 (#616)

## Settings

### QA-060 — Settings copy matches behaviour
- **Platforms:** both (manual, fresh account via `android-setup.sh --fresh`)
- **Expect:** every "on/off by default" claim matches the toggle's state on a
  fresh account; every setting changes something observable.
- **Origin:** A23 (#616, "Off by default" note under a toggle that was on);
  A24 (open: "Data usage: Wi-Fi only" is stored but never read on either app).

## Performance

### QA-050 — Idle CPU on the chat list
- **Platforms:** both (`scripts/qa/idle-cpu.sh`)
- **Expect:** ≤ 3 % averaged over 30–60 s with the app untouched on Home
  (baseline 2026-09-23: Android emulator 0.67 %, iOS simulator ~1.5 %).
- **How:** `android-smoke.sh` QA-050

### QA-051 — Cold start paints local state first
- **Platforms:** iOS (`scripts/bench/provision-and-bench.sh`), Android
  (`scripts/bench/android-chat-open-bench.sh`)
- **Expect:** within the baseline in `docs/PERFORMANCE.md`; relay work never
  on the critical path.

### QA-052 — Opening a read chat does not churn
- **Platforms:** core (both)
- **Expect:** re-marking an already-read conversation emits no change
  notification (no transcript rebuild loop).
- **Guard:** `client.rs::marking_an_already_read_conversation_does_not_notify` (#615)

## Open questions (need a product decision, not a fix)

- **Data usage (A24):** "Wi-Fi only" is stored but nothing reads it on either
  app, and the defaults differ (iOS Wi-Fi only, Android Always). Enforce it
  (gate media auto-download on metered links) or remove it.
- **Bitcoin mode default (A23):** both apps default to sats; the old copy
  claimed fiat. Which one is intended?

- **Fingerprint card (A3/A6):** iOS shows the Noise (mesh) key fingerprint,
  Android the nsec pubkey fingerprint — people comparing in person across
  platforms never match. Android also shows "Generating…" on the onboarding
  done step because the nsec is created on *Start chatting*.
