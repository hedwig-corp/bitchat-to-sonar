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

## MDK 0.8 → 0.10 upgrade (#613)

Build history on an MDK 0.8 install, then replace it **in place** with the
#613 build (MDK v0.10.4; it was v0.9.14 until the White Noise interop bump —
same `0xf2f1` wire, same migration) — never uninstall. "0.9" below and `09` in
`mdk-upgrade.sh` mean that post-port build. Needs two apps and two CLIs: build `main`
(pre-#613, 0.8) from a second checkout (`git worktree add --detach <dir>
<pre-613 commit>`) for both the app and `sonar-cli`, and this branch for the
0.9 ones. `scripts/qa/mdk-upgrade.sh` drives the peers (`peer <name> 08|09`,
`seed`, `upgrade-peer`, `send`/`expect`, `store`). iOS runs headless
(`SIMCTL_CHILD_SONAR_BENCH_NSEC`, same nsec before and after — the bench path
derives the DB key from it); Android through `android-ui.sh`. Seed at least one
chat above 80 messages (the first-paint extract window) and one image.

### QA-070 — In-place upgrade keeps every chat
- **Platforms:** iOS (headless), Android (UI)
- **Steps:** 0.8 app with ≥ 3 DMs from 0.8 peers (one > 80 msgs, one image) and
  a 3+ member room; install the #613 build in place; launch; wait 30 s.
- **Expect:** first paint shows the same rows, previews and unread dots
  (`SONAR_BENCH t1_local_paint groups=N`), and they are still there after relay
  attach (`t4_first_drain`, `home_rows … rows=N`); `mdk-upgrade.sh store` lists
  `*.mdk08.bak`, `.sonar-transcript.json` and the historical sidecars; sync
  resumes from its watermark (`sync() called … since_secs=` ≠ 0); no
  "Group chat · invite" row appears.
- **Guard:** `persistence.rs::boot_reconcile_keeps_recovered_08_history_and_live_sidecars`
- **Origin:** i2 (#613) — boot reconcile deleted every live sidecar on each
  store open: all recovered chats vanished ~1 s after launch, the bak and the
  transcript were gone, sync restarted from 0 and re-parked old 0.8 welcomes.

### QA-071 — Older recovered history pages in
- **Platforms:** Android (UI), iOS (sidecar check: `.sonar-transcript.json`
  holds every row after an idle minute)
- **Steps:** open the > 80-message recovered chat; scroll to the top.
- **Expect:** reaches message 1, including the rows only in the bak.
- **Guard:** `TranscriptDisplayPolicyTest.exhaustedSourceDoesNotDemandAnotherExpansion`
- **Origin:** A1 (#613) — every Compose chat stopped after one older page.
  Also stops after the second page **and on main** (tracked separately, see
  Open questions) — run it on a chat that fits in two pages until that lands.

### QA-072 — Send in a recovered chat once the peer updated
- **Platforms:** Android (UI); iOS covered by core e2e (no headless send)
- **Steps:** `mdk-upgrade.sh upgrade-peer <peer>`; send from the recovered row.
- **Expect:** "Sent · internet"; the peer's 0.9 CLI receives it; one row on
  Home; the new message sits under the recovered history.
- **Guard:** `e2e.rs::recovered_08_chat_resumes_on_a_new_09_group_through_a_relay`

### QA-073 — Peer still on 0.8
- **Platforms:** Android (UI)
- **Steps:** send in the recovered chat of a peer who has not upgraded.
- **Expect:** "Waiting for them to update Sonar" banner; no second row; no
  wipe. (The peer's own 0.8 sends never arrive — flag-day by design.)
- **Guard:** `e2e.rs::recovered_08_resume_with_a_peer_still_on_08_waits_for_their_update`
- **Origin:** A2 (#613) — the peer's 0.8 KeyPackage reached MDK 0.9 and the
  send failed with an opaque error and "Couldn't send".

### QA-074 — Upgraded peer messages first
- **Platforms:** iOS (headless), Android
- **Steps:** `upgrade-peer <peer>`; the peer sends to the app.
- **Expect:** the 0.9 DM auto-joins and folds onto the recovered row — still
  one row, now previewing the new message; `.sonar-historical-folds.json` maps
  hist → live; unchanged after a cold restart. Several contacts resuming within
  10 minutes all fold (the unknown-sender budget does not apply to them).
- **Guard:** `persistence.rs::recovered_08_contact_resume_welcome_bypasses_the_stranger_budget`
- **Origin:** i3 (#613) — recovered contacts counted as strangers.

### QA-075 — A recovered room stays a room
- **Platforms:** Android (UI)
- **Steps:** send in a recovered 3+ member room with one member upgraded.
- **Expect:** title and "only group members" banner kept; the upgraded member
  receives it in a group with the same name; no fold onto a 1:1.
- **Guard:** `e2e.rs::recovered_08_pending_room_send_creates_named_group_not_dm` (R-050)

### QA-076 — Chat history is sealed at rest
- **Platforms:** both (file check on the simulator App Group / `run-as`)
- **Steps:** after QA-070/074, `grep` a message body in the store directory.
- **Expect:** no match in `.sonar-transcript.json` / `.sonar-transcript.log`.
- **Guard:** `marmot.rs::transcript_rows_are_sealed_at_rest_and_survive_reopen`
- **Origin:** P1 (#613) — the 0.9 transcript was plaintext JSON and rewritten
  whole per message (17 ms at 10k rows).

### QA-077 — The checked-in Swift binding matches the core
- **Platforms:** iOS (CI: *Checked-in SonarFFI.swift matches the core*)
- **Expect:** `core/build-ios.sh` leaves `git status` clean.
- **Origin:** i1 (#613) — edited `///` doc comments moved two UniFFI checksums;
  a build from the committed binding would fatalError at launch.

## White Noise interop (#613)

White Noise iOS runs MDK's own runtime (marmot-app). The pinned MDK checkout
ships its CLI (`wn`/`wnd`) on the same runtime, so `scripts/qa/wn-interop.sh`
drives it against `sonar-cli` headlessly: `setup`, then `run [--members N]`,
which prints PASS/FAIL per id below. It needs a relay both clients share that
serves kind-1059 without NIP-42 and accepts 64 KiB events (see the script
header). Not covered: the White Noise iOS app UI and push, public-relay
overlap, NIP-42 inbox relays.

### QA-078 — White Noise starts a DM with a Sonar user
- **Platforms:** core (both apps)
- **Expect:** `wn groups create "" <sonar-npub>` succeeds; the Sonar user
  auto-joins and receives the message.
- **Guard:** `key_package_tags_match_white_noise_validation`,
  `key_package_offers_what_white_noise_requires_of_members`,
  `publishing_the_key_package_publishes_inbox_and_key_package_relay_lists`
- **Origin:** W1–W3 (#613): White Noise rejected every Sonar KeyPackage
  (`app_components` tag held `0x0001`), then required capabilities Sonar did
  not advertise, then had no kind-10050 inbox to deliver the welcome to.
  W6: White Noise on MDK v0.9.21+ (iOS ships v0.10.4) rejects an invitee
  KeyPackage that lists a default MLS capability, and every MDK 0.9.14
  package listed `0x0003` — fixed by the bump to v0.10.4
  (`key_package_lists_no_default_mls_capabilities`). Run the matrix against a
  `wn` built from the MDK tag White Noise iOS pins, not only Sonar's own pin.

### QA-079 — The Sonar reply stays in White Noise's DM
- **Platforms:** core
- **Expect:** `sonar-cli send --to <wn-npub>` reuses the chat White Noise
  created; White Noise shows the reply in it.

### QA-080 — Sonar starts a DM with a White Noise user
- **Platforms:** core
- **Expect:** White Noise lists the invite; after `groups accept` both sides
  exchange messages (White Noise catches up the first one on its next sync).

### QA-081 — A White Noise group with Sonar members
- **Platforms:** core
- **Expect:** every Sonar member joins and sees every message; White Noise sees
  the Sonar members' messages within ~10 s (its daemon ingests on its own
  cadence).

### QA-082 — A Sonar group with a White Noise member
- **Platforms:** core
- **Expect:** White Noise accepts and messages flow every way; `wn groups show`
  reports the encrypted-media component `0x800b` as required.
- **Guard:** `groups_sonar_creates_require_encrypted_media_v2`
- **Origin:** W5 (#613): without it White Noise refuses media in the group
  ("group does not require encrypted media").

### QA-083 — Encrypted media both ways
- **Platforms:** core
- **Expect:** a Sonar photo downloads and decrypts in White Noise, and a White
  Noise photo in a Sonar group decrypts in Sonar, byte-identical both ways.
- **Guard:** `new_uploads_use_the_layout_white_noise_parses`,
  `a_white_noise_tag_parses`, `mip04_uploads_keep_their_layout_and_open`
- **Origin:** W4 (#613): Sonar sent MIP-04 `mip04-v2` tags White Noise could not
  read (empty bubble) and dropped White Noise's `encrypted-media-v2` photos
  (caption only).

### QA-084 — A member's leave reaches everyone
- **Platforms:** core (both apps)
- **Expect:** after a Sonar member leaves, the remaining members' rosters (Sonar
  and White Noise) drop it within seconds, with no further input.
- **Guard:** `a_members_leave_is_committed_by_the_remaining_members`,
  `a_leave_queued_behind_a_converging_commit_still_produces_its_proposal`
- **Origin:** L1 (#613): MDK 0.9 commits a SelfRemove only from a convergence
  pass Sonar never ran, so the leaver stayed in every roster.
- **Not guarded:** White Noise's own `wn groups leave` proposals are deferred
  by every client, White Noise included (upstream, see Known gaps).

### QA-085 — 25-member groups both ways
- **Platforms:** core
- **Expect:** a 25-member group created by either side: every member joins,
  receives the creator's message, and replies reach everyone.
- **Guard:** `sonar-sim group-scale` (docs/GROUP-SCALE-SIM.md) for the ceiling.

### QA-086 — A White Noise member's own leave reaches the Sonar members
- **Platforms:** core (both apps)
- **Steps:** a Sonar user creates a group with a White Noise user and a second
  Sonar user; everyone joins; the White Noise user runs `wn groups leave`.
- **Expect:** both Sonar members' rosters drop to 2 within a minute, with no
  further input (one of them commits the SelfRemove from its convergence pass).
- **Guard:** `wn-interop.sh run` (QA-086); core
  `a_members_leave_is_committed_by_the_remaining_members` for the Sonar side.
- **Origin:** #613 bump to MDK v0.10.4. With the 0.9.14 `wn` and Sonar,
  every client deferred a White Noise leave (upstream marmot-protocol/mdk#1736,
  fixed in v0.9.19).

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

## Known gaps found by passes (tracked, not fixed here)

- **Compose load-older stops early (main too):** a chat opened at its unread
  anchor never loads older rows, and a read chat stops after the second older
  page (`firstVisibleItemIndex <= 2` never re-arms after a prepend). Seen on the
  `main` build in the #613 pass; not caused by #613.
- **Mesh realtime loop saturates the UI thread (main too):** with other BLE
  mesh peers in range (other agents' emulators) `startMeshRealtimeLoop` ran on
  the main dispatcher long enough to ANR the app. Turn Bluetooth off on a QA
  emulator that shares a host with other emulators.
- **White Noise's own leave was never committed (upstream, fixed):** with the
  MDK 0.9.14 `wn` CLI, a `wn groups leave` SelfRemove proposal was deferred
  (`TransportDeferred`) by every client, White Noise's own members included.
  Upstream marmot-protocol/mdk#1736, fixed by #1746 and released in v0.9.19. Not
  reproduced with the v0.10.4 `wn`. Sonar's own leave is committed by Sonar
  and White Noise members alike (QA-084).
- **Sonar sends welcomes to its own relays only:** White Noise reads welcomes
  from its kind-10050 inbox relays. Invites reach White Noise users through the
  usual shared relays (damus, primal, nos.lol); a White Noise user whose inbox
  relays share none with Sonar's would miss them. Publish welcomes to the
  invitee's kind-10050 relays too.
- **Queued sends fail instead of waiting:** MDK queues a send made while a
  commit is still converging (the ~1.1 s after a membership change) and
  regenerates it later. Sonar reports that send as failed ("send produced no
  application message") and does not publish the regenerated message. Leave
  is handled (QA-084); sends need the same queued-intent lifecycle.

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
