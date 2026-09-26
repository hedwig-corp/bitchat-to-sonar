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

## Share sheet (#559)

Sharing INTO Sonar from another app. iOS stages the share in the App Group
(`bitchatShareExtension`) and tries to open `sonar://share?id=…` — refused for
share extensions, so the extension says "Open Sonar to send" and the user
switches to Sonar, whose "Send to…" picker sends it. Android receives
`ACTION_SEND` directly.

`scripts/qa/ios-share-smoke.sh` (QA-080…092) drives all of it on the iOS simulator: the real
system share sheet, from the Files app and from a stand-in third-party app
(`scripts/qa/ios-share/QAShareHost`, a `UIActivityViewController` over file
URLs), picks the chat with a fresh `sonar-cli` peer and asserts on **what the
peer received** — filename, MIME and sha256 of the decrypted bytes — and that no
stray text message rode along. Every app-side screen looked fine while #559's
bug delivered a path, so the recipient is the only honest oracle.

Wire MIME: the app keeps MDK's allowlist (`snEncryptedAttachmentMime`) and sends
every other type as `application/octet-stream` with the extension intact — a
CSV arriving as `application/octet-stream` named `report.csv` is correct.

### QA-080 — A document from Files arrives as the file, not its path
- **Platforms:** iOS (automated); Android structurally immune (reads the
  `content://` stream, no type negotiation)
- **Steps:** Files → On My iPhone → long-press `report.csv` → Share → Sonar →
  pick the chat.
- **Expect:** picker lists `report.csv` (never `file URL`, never an `0-` prefix);
  the peer receives `report.csv`, bytes identical, and no text message.
- **How:** `ios-share-smoke.sh` QA-080 · Guard: `SonarSharePayloadTests.stagingNeverAsksAURLIdentifierForBytes`
- **Origin:** #559 — `loadFileRepresentation("public.file-url")` vends the
  path string; csv/txt/zip/docx shares delivered a ~110-byte blob named `file URL`.

### QA-081 — Documents from a third-party app keep names and bytes
- **Platforms:** iOS (automated)
- **Steps:** QA share host shares `data.json` + `archive.zip` → Sonar → chat.
- **Expect:** both arrive under their own names, bytes identical.
- **How:** `ios-share-smoke.sh` QA-081 · Guard: `SonarSharePayloadTests.stagedFilenamePrefersTheProviderName`

### QA-082 — Two same-named files both arrive, unprefixed, in order
- **Platforms:** iOS (automated); Android sends the `EXTRA_STREAM` list as-is
- **Steps:** host shares `dup1/IMG_0001.txt` + `dup2/IMG_0001.txt`.
- **Expect:** picker shows `IMG_0001.txt` twice, in the order shared, no
  `0-`/`1-`; the peer receives two `IMG_0001.txt` with the two distinct contents.
- **How:** `ios-share-smoke.sh` QA-082 · Guard: `SonarSharePayloadTests.stagedPathKeepsTheIndexOutOfTheFilename`
- **Origin:** #559 (index prefix leaked into the delivered name); order: QA
  pass on #559 — staging indexed by completion order shuffled multi-file shares.

### QA-083 — A photo file keeps its real name
- **Platforms:** iOS (automated)
- **Steps:** host shares `photo.png`.
- **Expect:** `photo.png`, `image/png`, same pixel dimensions. Not the same
  bytes: MDK strips EXIF by re-encoding every image it encrypts
  (`mdk-core` `encrypted_media/metadata.rs`), so a byte match is the wrong oracle.
- **How:** `ios-share-smoke.sh` QA-083

### QA-084 — An in-app text export is a file, never also the message
- **Platforms:** iOS (automated); Android N/A (text comes only from `EXTRA_TEXT`)
- **Steps:** the QA host exports `export.txt` from memory — its own
  `NSItemProvider`, bytes registered as `public.plain-text` plus a
  `suggestedName` (the usual "Export CSV" shape) → Sonar → chat.
- **Expect:** the picker preview shows the filename only, not the document's
  text; the peer receives `export.txt` and **no** text message.
- **How:** `ios-share-smoke.sh` QA-084 · Guard: `SonarSharePayloadTests.anInAppTextExportIsStagedAndNeverReadAsTheMessageBody`
- **Origin:** QA pass on #559 — the body reader read every provider, and a
  plain-text load of that provider returns the bytes: the staged manifest held
  `text` = the whole document AND the file. Files and file-URL shares do not
  show it (across the process boundary they vend a URL) — QA-091 keeps it so.

### QA-085 — A shared folder never copies the tree
- **Platforms:** iOS (automated)
- **Steps:** Files → long-press `Folder QA` → Share → Sonar.
- **Expect:** the extension says "no shareable content"; no picker; nothing in
  `SharedInbox` holds a directory; the peer receives nothing.
- **How:** `ios-share-smoke.sh` QA-085
- **Origin:** #559 review — `attributesOfItem[.size]` of a directory is its
  entry (~96 B), so it passed every size guard and `copyItem` copied the tree.

### QA-086 — A web link arrives as text, never as a file
- **Platforms:** both (iOS automated)
- **Steps:** host shares `https://sonar.hedwig.sh/qa-share-link`.
- **Expect:** the peer receives the link as text; no file.
- **How:** `ios-share-smoke.sh` QA-086 · Guard: `SonarSharePayloadTests` link cases
- **Origin:** #447 (links were staged twice, once as a file)

### QA-087 — An extension-less document keeps its name
- **Platforms:** iOS (automated)
- **Steps:** host shares `README`.
- **Expect:** the peer receives `README` (not `attachment`, not a type name).
- **How:** `ios-share-smoke.sh` QA-087

### QA-088 — An oversized file is refused before the picker
- **Platforms:** iOS (automated)
- **Steps:** host shares a 26 MiB file (cap: 25 MiB).
- **Expect:** "file is too large to share"; no picker; nothing left staged.
- **How:** `ios-share-smoke.sh` QA-088

### QA-089 — An abandoned share does not replace the one just made
- **Platforms:** both (iOS automated; Android by jvmTest)
- **Steps:** share `old-draft.csv`, switch to Sonar, leave its picker up and
  relaunch Sonar (the payload stays staged, as after a crash — the picker comes
  back); then share `fresh.csv` and switch to Sonar.
- **Expect:** the picker offers `fresh.csv`; the peer receives `fresh.csv`;
  `old-draft.csv` is offered again afterwards, not lost.
- **How:** `ios-share-smoke.sh` QA-089 · Guard: `SonarSharePayloadTests.theShareJustMadeIsOfferedBeforeAnOlderStagedOne`,
  `SonarSharePayloadTests.aNewerShareTakesOverAPickerShowingAnOlderOne`,
  `ShareQueueOrderTest` (Android)
- **Origin:** QA pass on #559 — the picker took the OLDEST staged payload and
  kept any picker already up, so it offered `old-draft.csv` and one tap sent
  it. The extension cannot open Sonar (`extensionContext.open` is refused for
  share extensions), so the app gets no payload id and must prefer the newest.
  Android queued a new share behind the open picker, and its Back button /
  system back stranded a queued share with no picker on screen.

### QA-090 — A photo from the Photos app arrives as an image
- **Platforms:** iOS (automated); Android manual (gallery → Share → Sonar)
- **Steps:** `simctl addmedia`, Photos → photo → Share → Sonar → chat.
- **Expect:** an `image/*` file with a real filename (Photos may re-encode, so
  bytes are not compared).
- **How:** `ios-share-smoke.sh` QA-090

### QA-091 — A text document from Files arrives as the file only
- **Platforms:** iOS (automated)
- **Steps:** Files → `notes.txt` → Share → Sonar → chat.
- **Expect:** `notes.txt`, `text/plain`, bytes identical, no text message.
- **How:** `ios-share-smoke.sh` QA-091

### QA-092 — Sharing while Sonar is not running
- **Platforms:** iOS (automated); Android receives `ACTION_SEND` by launching
  the activity, so the equivalent is covered by any Android share
- **Steps:** Sonar terminated; host shares `cold.csv` → Sonar (extension says
  "Open Sonar to send") → launch Sonar → tap the chat as soon as the picker
  shows (the store and relays are still starting).
- **Expect:** the picker comes up from the staged payload on the cold launch;
  the peer receives `cold.csv`, bytes identical.
- **How:** `ios-share-smoke.sh` QA-092
- **Origin:** QA pass on #559 — the most common real flow (the app is rarely
  running when a share starts); every other scenario had Sonar running.

## Reactions

Marmot NIP-25 kind-7 reactions (#603). Peers drive the other side with
`peers.sh react` / `peers.sh expect-reaction`; `peers.sh id-of` finds a
message id by its text. Retract (tapping your own chip) is a tracked gap —
MDK has no `deleteMessage` on the current pin — so a tap on your own chip does
nothing by design.

### QA-100 — React to an inbound message
- **Platforms:** both (Android automated; iOS via the XCUITest driver or by hand)
- **Steps:** a peer sends a text; long-press its bubble; tap 👍 in the reaction
  row at the top of the menu.
- **Expect:** the row shows ❤️ 👍 😂 😮 😢 🔥 on one line; the 👍 chip appears
  under the bubble at once (before any relay ack) with the "mine" outline, and
  sits below the text and time instead of covering them; the app does not
  crash; the peer sees the reaction on that exact message
  (`peers.sh expect-reaction <peer> 👍 60 <id>`); the chat-list row keeps the
  text preview and gains no unread badge.
- **How:** `android-smoke.sh` QA-100 · Guard: `TranscriptCellKindChangeTests`,
  `SNTextBubbleLayoutTests.textRowsOfferTheReactionRowOnLongPress`,
  `ReactionRowPlacementUiTest`
- **Origin:** #603 QA — i1 (iOS crashed with NSInternalInconsistencyException
  when a visible UIKit text row gained its first chip: the row changed cell
  class on `reconfigureItems`), i2 (plain text rows, drawn by the UIKit cell,
  had no reaction row in their menu, so they could not get a first reaction),
  A1 (Compose drew the chips over the bubble's last line and time).

### QA-101 — A peer reacts to my message
- **Platforms:** both (Android automated)
- **Steps:** with the chat open, the app sends a text; the peer reacts 🔥 to it.
  Then leave the chat and let the peer react 😂 while the app is on the list.
- **Expect:** the 🔥 chip appears in the open chat within ~10 s without a reload
  flash; on the list the row keeps the text preview, its time does not move,
  there is no unread badge and no notification (R-017).
- **How:** `android-smoke.sh` QA-101 · Guard: `e2e.rs::kind7_reaction_does_not_notify_or_increment_unread`

### QA-102 — Several emojis and counts
- **Platforms:** both (Android automated)
- **Steps:** on one message the app reacts 👍 and 🔥 and the peer reacts 👍.
- **Expect:** two chips: 👍 with count 2 (mine) and 🔥 (mine). Tapping the
  peer-only chip of another message adds mine; tapping my own chip does
  nothing (no duplicate kind-7 reaches the peer).
- **How:** `android-smoke.sh` QA-102

### QA-106 — React to a photo
- **Platforms:** both (Android automated; iOS: `ios-drive.sh … "longpress:Photo;tap:😮"`)
- **Steps:** a peer sends a photo (`peers.sh send-image`); long-press the photo;
  tap 😮. Then tap the photo once.
- **Expect:** the long-press opens the message menu with the reaction row (not
  the viewer); the 😮 chip sits under the photo and the peer gets it on that
  message (`peers.sh id-of-media`); a single tap still opens the viewer. The
  photo is announced as "Photo".
- **How:** `android-smoke.sh` QA-106 · Guard: `ReactionRowPlacementUiTest.longPressOnContentThatOwnsItsTapOpensTheReactionRow`
- **Origin:** #603 QA — A5: on Android the photo's own `clickable` consumed
  the press, so the row's long-press menu never opened on media and a photo
  could not get a reaction (iOS could). Photos were also unlabelled for
  screen readers on both apps.

### QA-103 — Chips survive traffic in other chats
- **Platforms:** iOS (the Compose summary refresh does not touch transcript rows)
- **Steps:** chat A is open with a chip on a message; a second peer messages
  the app (a different chat).
- **Expect:** the chip in chat A stays, and tapping that emoji again does not
  send a duplicate.
- **Guard:** `ConversationTranscriptWindowTests.tallyFreeSummaryMergeKeepsLoadedChips`
- **Origin:** #603 QA — i3: the chat-list summary read (`recentMessagePages`)
  is tally-free by design, and merging it replaced the open chat's rows,
  wiping every chip whenever any chat received a message.

### QA-104 — Reacting to an older message keeps the scroll position
- **Platforms:** both (manual)
- **Steps:** seed a long chat: `sonar-cli --home <peer> send --to <app-npub>
  --text "long history" --repeat 560` (one process; waits for the relays).
  Open it, scroll to the oldest rows, and react to one of them.
- **Expect:** the chip appears in place; the rows on screen do not move and
  the transcript does not jump to the newest page; the peer gets the reaction.
- **Origin:** #603 review — A2: Compose reused the send path's newest-page
  reload for reactions. Verified 2026-09-26 on a 560-message chat (Android):
  no jump, chip in place, delivered. A control build with the old reload did
  not jump in the same flow either — the window-pinned state that the old
  reload acted on was not reached with 560 rows — so the fix (a reaction no
  longer reloads anything) is verified by construction, not by reproduction.

### QA-105 — Reactions survive a relaunch, and the index is not plaintext
- **Platforms:** both (Android: `run-as`; iOS: the simulator's app container)
- **Steps:** after QA-102, force-stop and relaunch; open the chat. Then look at
  `marmot.sqlite.sonar-reactions.json` beside the chat database.
- **Expect:** the chips paint with the first local frame (no relay wait); the
  file holds no emoji, no npub/hex pubkey and no message id in the clear, and
  no `.sonar-reactions.dirty` marker is left once the app is idle.
- **Guard:** `reaction.rs::sidecar_is_sealed_not_plaintext`,
  `persistence.rs::duplicate_reaction_does_not_leave_the_index_dirty`,
  `persistence.rs::reaction_index_survives_engine_reopen`
- **Origin:** #603 QA — c1 (the index of who reacted with what, in which
  group, was written as plaintext JSON next to the SQLCipher database), c2 (a
  duplicate or failed kind-7 left the dirty marker set, so every open — and
  every iOS notification-extension wake — rebuilt the index, and a failed
  rebuild refused to open the account's chats).

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
- **Platforms:** Android automated (`uiautomator dump` content-desc); iOS
  `ios-drive.sh … tree:<name>` or Accessibility Inspector
- **Expect:** send, attach, emoji, voice, back, call, settings, start-chat, the
  nickname, search and composer fields all have spoken labels (`android-ui.sh
  dump` shows an unlabelled field as `E!` — uiautomator's NAF flag; an iOS tree
  shows it as a `Button`/`TextField` row with no `label:`).
- **How:** `android-smoke.sh` QA-040 checks the chat screen (attach, emoji,
  send/record, back, composer field), home (settings, start-chat, nearby) and
  the search field. Manual: the nickname field (onboarding only, use
  `android-setup.sh --fresh`) and call buttons (call-capable peers only).
  Channel controls: QA-042. Guard: `IconButtonAccessibilityUiTest`. iOS: dump
  the tree of a chat (Back, Add to your message, Emoji and stickers, Record
  voice message → Send while typing) and home; `SNIconButton` takes its label
  as a required argument, so a new header icon without one does not compile.
  The recording mic is one element with a VoiceOver activate action (start /
  send), since its press-and-hold gesture cannot be performed by VoiceOver.
- **Origin:** A9/A5/A21 (#616); iOS: every `SNIconButton` (back, call, video,
  settings, nearby, bookmark, edit-name, close) and the composer's plus, emoji,
  mic and send were read as "button" (QA follow-up to #616)

### QA-041 — Profile QR is a real, scannable code
- **Platforms:** both (Android automated on macOS; iOS manual)
- **Steps:** Settings → profile card → screenshot the "Your key" card.
- **Expect:** the code decodes (any QR reader, or
  `swift scripts/qa/qr-decode.swift shot.png`) to the account's npub.
- **How:** `android-smoke.sh` QA-041
- **Origin:** A25 (#616) — Android drew the design mock's decorative pattern
  under "Let someone scan this to add you"; nothing could scan it.

### QA-043 — Accessibility sweep: no unlabelled controls
- **Platforms:** Android automated (`android-ui.sh naf` per screen); iOS
  `ios-drive.sh` tree dump per screen, or an Accessibility Inspector audit
- **Expect:** zero NAF nodes on home, search, start-chat, nearby, settings, a
  chat and its contact profile (extend the sweep when a screen is added).
- **How:** `android-smoke.sh` QA-043. iOS: `ios-drive.sh <name>
  "launch;<navigate>;tree:t"` for the same screens plus the Mesh channel, the
  emoji tray and a chat with reaction chips, then grep each dump for
  `Button`/`TextField` rows without `label:` — none expected.
- **Origin:** A28 (#616) — contact-profile action circles were NAF and their
  captions were dead taps; the 2026-09-24 sweep of every main screen is clean.
  iOS had the same two gaps (the Message/Call/Pay/Verify circles and the
  placeholder-only search field); the 2026-09-27 sweep of all of the above,
  reaction chips included, is clean.
- **Also:** every settings toggle is a switch that reports its state
  (uiautomator `checkable="true"` and `checked` match the switch; VoiceOver
  reads "On"/"Off"). `android-smoke.sh` QA-043 checks "Share local time" is a
  switch; QA-093 checks its state follows taps. Guard: `SettingsToggleSemanticsUiTest`,
  `SNPeerLocalTimeFormatterTests.toggleRowsSpeakTheirState`. Origin: #607 QA
  (no toggle exposed its state on Compose; iOS read it as a plain button).

### QA-042 — Channel screen controls are labelled
- **Platforms:** Android (manual: open any location channel, `android-ui.sh dump`)
- **Expect:** back, bookmark ("toggle bookmark for #…"), Nearby, the composer
  ("Message <channel>") and Send are all labelled; no `E!` rows.
- **Origin:** A22 (#616)

## Private local time (#607)

Kind-449 timezone shares ride inside MLS (kind 445), never as a transcript
row. `peers.sh share-tz` / `expect-tz` drive the peer side: a CLI peer can
share a zone with the app and report the zone the app shared with it.

### QA-070 — Sharing is off by default
- **Platforms:** both (Android automated)
- **Steps:** on an account that never touched the setting, open a chat with a
  fresh peer and exchange a message; wait 30 s.
- **Expect:** Settings → Privacy & safety → *Share local time* is off; the
  peer never receives a zone (`peers.sh expect-tz` times out).
- **How:** `android-smoke.sh` QA-070 · Guard:
  `client.rs::timezone_share_only_publishes_to_allowlisted_groups`

### QA-071 — Enabling the Settings default shares with existing chats
- **Platforms:** both (Android automated)
- **Steps:** with QA-070's chat, turn *Share local time* on in Settings.
- **Expect:** the peer receives the device's IANA zone within 60 s; nothing
  appears in the transcript on either side.
- **How:** `android-smoke.sh` QA-071

### QA-072 — A peer's zone paints the DM header, silently
- **Platforms:** both (Android automated)
- **Steps:** the peer runs `peers.sh share-tz <peer> <app-npub> Asia/Kolkata`
  while the app shows the chat list, then open the chat.
- **Expect:** the header subtitle reads `<time> · <offset> ahead|behind`
  (`5h 30m` for a half-hour zone); no new bubble, no unread dot, no
  notification, and the chat does not jump to the top of the list.
- **How:** `android-smoke.sh` QA-072 · Guard:
  `e2e.rs::timezone_share_does_not_notify_or_increment_unread`,
  `PrivateTimezoneTest`, `SNPeerLocalTimeFormatterTests`

### QA-073 — Per-chat override beats the Settings default
- **Platforms:** both (manual)
- **Steps:** Settings on; contact profile → Privacy → turn *Share local time*
  off for chat A; keep chat B on. Change the device timezone (Android:
  `adb shell service call alarm 3 s16 <zone>`; iOS simulator: host timezone).
- **Expect:** B's peer receives the new zone; A's peer does not. The note
  under the toggle says "Off for this chat — overrides your Settings default"
  only when A has its own override; with Settings off and no override it says
  "Off — follows your Settings default". Turning Settings off while A is
  overridden *on* keeps sharing with A only.
- **Guard:** `PrivateTimezoneTest.offNoteSaysWhetherTheChatOverridesTheDefault`,
  `SNPeerLocalTimeFormatterTests.offNoteSaysWhetherTheChatOverridesTheDefault`
- **Origin:** U1 (#607 QA — the "overrides" note showed on every chat that
  simply followed an off default)

### QA-074 — A device timezone change republishes
- **Platforms:** both (manual; Android via `service call alarm 3 s16`)
- **Steps:** sharing on; change the device timezone.
- **Expect:** each allowed peer receives the new zone within 60 s; the
  group-info "You" row, the contact/group notes ("Sharing <zone> …") and every
  visible peer clock update at once, not at the next minute tick.
- **Origin:** A2 (#607 QA — Compose read the zone during composition, so the
  notes kept naming the old zone)

### QA-075 — Group member list shows local times
- **Platforms:** both (manual)
- **Steps:** the app creates a group with two fresh peers (*Start a chat* →
  *New group*); `peers.sh accept <peer>` for each; one peer runs
  `peers.sh share-tz-group <peer> <group-hex> Europe/Lisbon` (`peers.sh groups`
  prints the hex). Open Group info, stay on it across a minute boundary.
- **Expect:** `Local time: <time>` under every member whose zone is known,
  including "You"; members that never shared show no line; the "You" clock
  keeps ticking even when no peer has shared. Turning the group's own toggle
  on shares into the group (`peers.sh expect-tz`).
- **Guard:** `client.rs::timezone_share_resends_when_a_member_is_swapped`
  (a swapped-in member gets the zone)
- **Origin:** i3 (#607 QA — the iOS "You" clock froze until a peer shared)

### QA-076 — Wipe and erase clear the preference
- **Platforms:** both (manual)
- **Expect:** *Erase chats* drops every per-chat override (Settings default
  survives); a full account wipe resets *Share local time* to off.

### QA-077 — A restart does not re-share the zone
- **Platforms:** both (Android: `am force-stop` + launch; iOS: `simctl
  terminate` + launch)
- **Steps:** sharing on and delivered (`peers.sh tz <peer>` shows the zone);
  note its `updated_at_secs`; relaunch the app twice, 30 s each.
- **Expect:** the peer's `updated_at_secs` does not move — a restart with the
  same zone sends nothing. A real zone change still arrives.
- **Guard:** `client.rs::timezone_share_is_not_repeated_after_restart`
- **Origin:** A1/i2 (#607 QA — every launch, and every iOS store reopen,
  re-encrypted a kind-449 into every allowed group: 37 per launch)

### QA-093 — Turning sharing off withdraws your time
- **Platforms:** both (Android automated; iOS manual)
- **Steps:** sharing on and delivered to peer A (`peers.sh expect-tz`); turn
  the chat's own toggle off (or the Settings default, for chats following it).
- **Expect:** within 60 s the peer no longer has your zone
  (`peers.sh expect-no-tz <peer> <app-npub>`); a group you still share with
  keeps it. The reverse: when a peer runs `peers.sh revoke-tz`, the app's DM
  header drops the clock and shows the encryption line again, with no bubble,
  unread or notification.
- **How:** `android-smoke.sh` QA-093 (also asserts the Settings switch reports
  on/off as it flips). iOS, by hand: flip the DM's toggle in contact info and
  watch `peers.sh tz <peer>` — each line carries `group_id`, so the DM entry
  must come and go while a shared group's entry stays (`expect-no-tz` checks
  every group, so it only passes once the group is off too). Then
  `peers.sh share-tz` → header clock, `peers.sh revoke-tz` → clock gone, and it
  stays gone after a cold relaunch (the resync must not replay the older share).
- **Guard:** `client.rs::timezone_revoke_hides_the_zone_only_in_its_own_group`,
  `client.rs::timezone_revoke_is_sent_only_where_a_share_was_sent`,
  `e2e.rs::timezone_revoke_reaches_the_peer_over_the_relay`,
  `conversation_index.rs::revoke_tombstone_is_per_group_and_blocks_older_replays`
- **Origin:** #607 known gap — a stale clock stayed after sharing was off.
## Desktop Bluetooth mesh (#612)

The desktop mesh engine (`MeshLink.kt`) is driven headlessly against the REAL
Android phone engine (`MeshLinkEngine`, the Rust `mesh_engine`) by
`DesktopMeshInteropTest`: a simulated radio with both GATT roles, virtual time
and per-hop latency. It runs in `:composeApp:jvmTest`, so CI covers it. The
hardware legs need a desktop plus real phones; debug both ends with
`SONAR_BLE_DEBUG=1` (the log lands in `~/Library/Logs/sonar/sonar-ble.log` or
`~/.local/state/sonar/sonar-ble.log`) and `adb logcat -s MeshGatt:* MeshRadio:*`.
Which role the desktop plays is in the log: `advertise: started` means phones
dial it (QA-131); `start_advertising REFUSED` or `register_gatt FAILED` means it
dials them (`link <tag>: up`, QA-128…084).

### QA-126 — The desktop Mesh channel tells the truth
- **Platforms:** desktop (automated + manual)
- **Steps:** desktop app → Mesh channel.
- **Expect:** "The Mesh channel isn't available here yet", naming Bluetooth
  DMs as still working; no composer, only "Sending is unavailable on Bluetooth
  mesh here." Desktop has no 0x02 public-message path, so a composer there only
  ever echoed locally and promised the send "will reach people as they connect".
- **Guard:** `DesktopMeshChannelNoticeTest.theDesktopMeshChannelSaysWhatStillWorks`
  (asks the real desktop capability, not an override)
- **Origin:** D1 (#612 QA — the channel was gated on the DM capability, so every
  machine where Bluetooth DMs work got the composer back, i.e. #609 unfixed)

### QA-127 — The Android Mesh channel keeps its composer
- **Platforms:** Android (automated)
- **Steps:** home → *Mesh* card → the Mesh channel.
- **Expect:** "Bluetooth mesh" empty state and the "Message Mesh" composer; no
  "isn't available" notice.
- **How:** `android-smoke.sh` QA-127 · Guard:
  `DesktopMeshChannelNoticeTest.aWorkingMeshRadioGetsANormalChannel`

### QA-128 — A desktop that dials a phone links and carries DMs both ways
- **Platforms:** desktop Linux ↔ Android (automated; hardware manual)
- **Steps:** a Linux desktop whose controller refuses to advertise, a phone in
  range with Sonar open; wait for the phone on the desktop radar; DM each way.
- **Expect:** `Noise handshake started` then `ESTABLISHED` on the desktop, the
  phone shows the desktop as in range, both DMs arrive over Bluetooth.
- **Guard:** `DesktopMeshInteropTest.aDesktopThatDialsAPhoneStartsTheHandshake`

### QA-129 — A dropped link is re-handshaken, not left half-dead
- **Platforms:** desktop Linux ↔ Android (automated; hardware manual)
- **Steps:** QA-128 linked; toggle Bluetooth on the phone (or walk out of range
  and back); DM each way once the phone reappears.
- **Expect:** `link to <name> dropped → Noise session reset`, a fresh handshake
  on the new link, both DMs delivered. Android drops its Noise state with the
  GATT connection and never initiates toward a central, so a kept session
  showed the phone in range while every DM was silently discarded.
- **Guard:** `DesktopMeshInteropTest.aDroppedLinkIsRehandshakenNotLeftHalfDead`
- **Origin:** D2 (#612 QA)

### QA-130 — Two phones in range link independently
- **Platforms:** desktop Linux ↔ 2× Android (automated; hardware manual)
- **Expect:** both phones link; a DM to one never reaches the other. Android
  answers a handshake whatever its recipient id says, so an m1 written to every
  link reset the other phone's responder.
- **Guard:** `DesktopMeshInteropTest.twoPhonesLinkIndependently`, `sonar-ble`
  `a_routed_packet_reaches_only_its_link` / `a_broadcast_reaches_every_link`
- **Origin:** D3 (#612 QA)

### QA-131 — A phone that dials the desktop links without a stall (macOS)
- **Platforms:** desktop macOS ↔ Android / iPhone (automated; hardware manual)
- **Steps:** macOS desktop (advertising works) and a phone; DM each way.
- **Expect:** the phone initiates and the desktop answers (`ESTABLISHED`
  without `handshake started` on the desktop), within a few seconds. An m1 from
  the desktop on this path reset the phone's own initiator, which retries only
  after 8 s.
- **Guard:** `DesktopMeshInteropTest.aPhoneThatDialsTheDesktopLinksWithoutAStall`
- **Origin:** D4 (#612 QA)

### QA-132 — A lost handshake message is retried
- **Platforms:** desktop (automated only)
- **Expect:** a handshake that stops moving is abandoned after 8 s and, on a
  link the desktop dialed, restarted at once.
- **Guard:** `DesktopMeshInteropTest.aLostHandshakeMessageIsRetried`
- **Origin:** D5 (#612 QA — one lost m1 left the session in flight forever)

### QA-133 — An iPhone on a link the desktop dialed
- **Platforms:** desktop Linux ↔ iPhone (automated model; hardware manual)
- **Steps:** as QA-128 with an iPhone; send a DM from the iPhone first.
- **Expect:** one handshake completes (`simultaneous Noise open … keeping
  ours` may appear once); both ends can decrypt.
- **Guard:** `DesktopMeshInteropTest.aSimultaneousOpenWithIosConverges` (iOS
  modelled from `NoiseSessionManager.swift`, not run)
- **Origin:** D6 (#612 QA)

### QA-134 — A long DM crosses in both directions
- **Platforms:** desktop ↔ Android / iPhone (automated; hardware manual)
- **Steps:** once linked (QA-128 or QA-131), send a ~500-character DM each way.
- **Expect:** both arrive whole. Anything over 480 bytes travels as 0x20
  fragments of 205 bytes, which the desktop neither reassembled nor produced,
  so every long DM from a phone vanished silently.
- **Guard:** `DesktopMeshInteropTest.aLongDmCrossesInBothDirections` (the
  simulated radio enforces a 517-byte ATT MTU)
- **Origin:** D7 (#612 QA — pre-existing, older than the central link)

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
- **Control first:** with location channels live (emulator location set, a
  "<city> · N here now" card on Home) geo-relay reconnects and presence
  fetches alone put `main` at 3.6–4.1 % on the emulator (2026-09-25, #607
  pass; ~200–300 `relay EOSE` lines/min). A number over budget is only a
  finding when a `main` build on the same emulator/account measures lower.
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

### QA-053 — Idle with other Sonar devices advertising nearby
- **Platforms:** Android (iOS already scans on its own `bleQueue`)
- **Steps:** boot a second emulator of your own with Sonar onboarded and
  Bluetooth on (every emulator on a Mac shares one virtual BLE radio); leave
  the app under test idle on Home with Bluetooth on for 60 s.
- **Expect:** no "Sonar isn't responding"; main-thread CPU stays near idle
  (`/proc/<pid>/task/<pid>/stat` utime+stime); the two devices still link
  ("Mesh · 1 here now", logcat `Noise link ESTABLISHED`).
- **Guard:** `MeshScanThrottleTest` (the throttle); the move off the main
  looper is checked here, by hand.
- **Origin:** #603 QA — `MeshRadio.onScanResult` ran UniFFI calls
  (`isLinkedAddr`, `shouldDial`, `connect` under `txLock`) on the main looper
  for every advertisement. With other agents' Sonar emulators around: repeated
  ANRs and 23–26 % idle CPU on Home, the same on a `main` build. With one
  advertiser, main-thread time went 68 → 32 ticks/60 s after the fix.

## Wallet (Cashu)

Money scenarios never need real sats: point a DEBUG iOS build at a local
`cdk-mintd` with `ln_backend = "fakewallet"` (the `sonar.debug.cashuMintURL`
override; recipe in `SonarCashuStorage`), and use a second fakewallet mint for
"foreign" invoices. The DEBUG override is also read from the launch arguments
(`simctl launch <udid> sh.hedwig.sonar -sonar.debug.cashuMintURL <url>`). To
reproduce what a real network does to a payment, put
`scripts/qa/mint-proxy.py` between the app and the mint and arm one fault at
a time (a lost melt answer, a melt request that arrives late or never, a mint
answer past the wallet's deadline); `sonar-cashu-cli --mint <proxy>` drives
the same core headlessly. Steps that only read from the mint (offer, invoice, fee
quote) are safe against `mint.hedwig.sh`. The Compose build has no mint
override, so on Android the money-moving scenarios stay manual against the
real mint and need the maintainer's approval of the amounts.

### QA-107 — Receive shows a real, reusable offer
- **Platforms:** both (Android automated; iOS manual)
- **Steps:** Settings → Balance → **Receive**.
- **Expect:** the Wallet screen does not stay on "Mint offline — retrying"
  (the offer is cached, so a QR alone passes over a broken store); the QR
  decodes to a BOLT12 offer (`lno1…`); Copy puts the full
  offer on the clipboard ("Copied" for ~1.7 s); caption "Anyone can pay this
  address — any amount, as often as they like."; with no mint yet, "Your
  wallet is still connecting to the mint." instead of a QR.
- **How:** `android-smoke.sh` QA-107 · Guard: `receive_offer_is_stable_across_calls_reconnects_and_offline`
- **Origin:** #614 (the wallet had no way to be funded from outside).

### QA-108 — One-time invoice for an amount, retired once paid
- **Platforms:** both (manual, fake mint)
- **Steps:** Receive → *Request an amount* 210 → *Create invoice* → pay it.
- **Expect:** the QR swaps to an `lnbc…` invoice, caption "One-time invoice
  for …"; when **that** payment lands, "Received …" shows and the sheet goes
  back to the reusable address. A same-sized payment to the offer does not
  retire the invoice.
- **Guard:** `a_bolt11_invoice_is_paid_under_the_id_it_was_issued_with` (core),
  `a_paid_invoice_arrives_under_its_payment_id` (FFI),
  `CashuWalletUXTests.testOnlyTheShownInvoicesPaymentRetiresIt`,
  `PayFooterTest.onlyTheShownInvoicesPaymentRetiresIt`
- **Origin:** #614 (a paid one-time invoice stayed on screen as payable).

### QA-109 — The fee is shown before confirming, in sats
- **Platforms:** both (manual)
- **Steps:** with fiat display on, Send → paste an invoice or offer → open the
  confirm sheet; change the amount.
- **Expect:** "Checking the fee…" then "Network fee: up to N **sats**" (never
  "CHF 0.00"), re-quoted after the amount settles; Send waits only while
  "Checking the fee…" shows (a failed quote hides the line and does not block
  — see QA-124). The footer reads "Pays this Lightning invoice." / "Pays this
  Bolt12 offer.", never "Pays lnbc…'s wallet".
- **Guard:** `CashuWalletUXTests.testPaySheetFeeLineIsAlwaysInSats`,
  `testFeeLineShowsTheQuotedFee`, `testPaySheetFooterNamesInvoicesAndOffersNotPeople`,
  `PayFooterTest.theFeeLineIsAlwaysInSats`, `aRawLightningInvoiceIsNotAName`
- **Origin:** #614 (fee hidden until after consent; a 1-sat reserve shown as
  "CHF 0.00"; raw invoices named as people).

### QA-110 — A pasted invoice shows its exact amount
- **Platforms:** both (manual; exhaustive by unit test)
- **Steps:** paste a `lnbc2100n…` invoice (210 sats) into Send.
- **Expect:** the sheet says **210** sats (not 211); after paying, the
  activity row is −210.
- **Guard:** `Bolt11AmountTest.wholeSatAmountsAreExactNeverRoundedUp`,
  `CashuWalletUXTests.testBolt11WholeSatAmountsAreExact`
- **Origin:** #614 (floating-point parse read 210.00000000000003 and rounded up).

### QA-111 — A send the mint refuses settles as Failed
- **Platforms:** both (manual, fake mint: pay an invoice the mint has already
  paid itself)
- **Steps:** send; relaunch the app if a row from an older build is still
  "Taking longer than usual · still in flight".
- **Expect:** the row reads "Failed", the amount is struck through, the
  balance is unchanged; a stuck row settles to Failed on the next connect.
- **Guard:** `a_melt_the_mint_refuses_is_failed_not_in_flight`,
  `a_refused_melt_is_failed_in_history_and_lookup`,
  `a_pending_melt_the_mint_later_fails_is_reported_and_refunded`
- **Origin:** #614 (a refused send stayed "still in flight" forever).

### QA-112 — Restore brings the ecash back
- **Platforms:** both (manual)
- **Steps:** Settings → Restore account with an nsec whose wallet holds ecash.
- **Expect:** after the wallet connects, the balance matches the old wallet's
  (NUT-13 restore); the previous account's `sonar-cashu/<id>/` stays on disk;
  the sheet says "Your wallet is rebuilt…", not "Lightning wallet".
- **Guard:** `connect_restores_again_after_proof_db_is_deleted`,
  `surviving_restore_marker_does_not_skip_nut13_when_proof_db_is_gone` (R-050)
- **Origin:** #614.

### QA-113 — Chat ⚡PAY to a contact
- **Platforms:** both (manual; the payee can be headless: a `sonar-cli` peer
  whose descriptor carries a second wallet's offer on the same mint)
- **Steps:** open the chat → + → *Send money* → amount → Send.
- **Expect:** the fee line prices the contact's cached offer; the bubble reads
  "Paid"; the peer receives `⚡PAY` then `⚡PAYDONE`; the payee's wallet
  mints the amount. Same-mint payments settle internally and carry no
  preimage (known gap, `docs/WALLET-INTEGRATION.md`), so the receipt says
  "They received N sats." and never claims a "cryptographic proof".
- **Guard:** `PaymentStatusTest.aSettledPaymentNeverClaimsAProofItMayNotHave`,
  `SonarPaymentStatusTests.testASettledPaymentNeverClaimsAProofItMayNotHave`
- **Origin:** #614 (QA pass: the receipt promised a proof an internal
  settlement does not have).

### QA-114 — Two Sonars in Bluetooth range, both with a wallet
- **Platforms:** Android (two emulators share the virtual Bluetooth medium,
  so any second running Sonar emulator is a mesh peer); iOS sends no offer in
  its announce
- **Steps:** onboard, let the wallet publish its offer, keep the app open
  with another Sonar in range for 2 min.
- **Expect:** the peer shows up ("1 here now") and the app never crashes;
  logcat has no `max length of an attribute value`.
- **Guard:** `WalletAppStateTest.theMeshAnnounceCarryingTheCashuOfferFitsOneBleAttribute`
  (real `SonarAppState` → real mesh engine framing; red without the fix)
- **Origin:** #614 QA pass — every install now has a ~400-char mint offer; the
  0x53 announce carried it, a > 512-byte GATT notify/write threw on Android
  13+, and the app crash-looped whenever another Sonar was near.

### QA-115 — The wallet store survives background/foreground churn
- **Platforms:** Android first (no redb file lock there), then iOS
- **Steps:** with the wallet connected, press HOME and relaunch 40 times at
  random 0.3–3 s intervals (throttle the emulator network,
  `adb emu network speed gsm`, to keep syncs in flight); then open the wallet.
- **Expect:** logcat never shows `DB corrupted` or `Database already open`;
  the wallet reconnects and shows its balance, not "Mint offline — retrying".
- **Guard:** `a_reconnect_while_the_old_wallet_is_still_in_use_shares_its_store`
  (core; fails with "Database already open" without the fix)
- **Origin:** #614 QA pass — the Android store came back "All roots are
  corrupted" after a session of crashes and lifecycle churn: a reconnect
  opened a second redb writer while an in-flight call held the old wallet,
  and Rust's std has no file lock on Android to refuse it.

### QA-116 — A damaged wallet store is rebuilt from the key
- **Platforms:** both (Android automated; iOS manual on the fake-mint simulator)
- **Steps:** with the app stopped, damage `sonar-cashu/<id>/mainnet/cashu.redb`
  (Android: `run-as` + `dd` over the header; iOS: the app container), relaunch,
  open the wallet.
- **Expect:** the wallet comes online (never stuck on "Mint offline —
  retrying"), the balance comes back through the NUT-13 restore, and the
  damaged file is kept as `cashu.redb.corrupt-<secs>`.
- **How:** `android-smoke.sh` QA-116 · Guard:
  `a_corrupted_store_is_set_aside_and_rebuilt_from_the_seed`,
  `a_store_that_panics_redb_on_open_is_rebuilt_too`
- **Origin:** #614 QA pass — a corrupted store failed every connect forever;
  some damage made redb panic inside connect.

### QA-117 — A payment from outside Sonar raises a banner
- **Platforms:** both (manual; iOS on the fake mint, whose invoices pay
  themselves)
- **Steps:** Receive → request an amount → create the invoice (or have an
  outside wallet pay the offer) with the app open.
- **Expect:** one "Payment received" notification ("N sats received."), not
  repeated when the payment is replayed, and none for our own sends. It
  comes about 30 s after the payment: the wallet first waits for a chat ⚡PAY
  line that would announce it (QA-119).
- **Guard:** `WalletReceiveNotificationTests.testAnOutsidePaymentIsAnnouncedOnceWhenItSettles`,
  `WalletAppStateTest.anOutsidePaymentIsAnnouncedOnceWhenItSettles`
- **Origin:** #614 — an outside payment has no chat line, so nothing
  announced it; the money just appeared.

### QA-119 — A chat ⚡PAY is announced once
- **Platforms:** both (manual; iOS on the fake mint: a `sonar-cli` peer sends
  the `⚡PAY|1|<hex>|<sats>` line and `sonar-cashu-cli` pays the app's offer
  from a funded fake-mint wallet)
- **Steps:** with the app open, (a) the peer sends ⚡PAY for N sats, then the
  offer is paid N; (b) the offer is paid M, then within 30 s the peer sends
  ⚡PAY for M; (c) the offer is paid K with no ⚡PAY.
- **Expect:** no "Payment received" banner for (a) or (b), whose chat line
  announces them; one banner for (c) after about 30 s. Check the system log
  for `sonar-payment-wallet-<quote id>` requests.
- **Guard:** `WalletReceiveNotificationTests.testAChatPaymentIsAnnouncedByItsChatLineOnly`,
  `WalletAppStateTest.aChatPaymentIsAnnouncedByItsChatLineOnly`,
  `ReceiveAnnouncerTest`
- **Origin:** #614 — every chat payment raised the chat notification and a
  second "Payment received" banner from the wallet.

### QA-118 — A reinstall keeps the same receive offer
- **Platforms:** both (Android automated, destructive: `QA_ALLOW_WIPE=1` on a
  throwaway emulator; iOS manual: delete and reinstall on a throwaway
  simulator. The simulator keeps the key in the Keychain, so the account
  comes back without a restore; on the fake mint write the DEBUG mint
  override before the first launch, or the wallet merges against the real
  mint first)
- **Steps:** restore a throwaway key, read the Receive QR, wait for the offer
  to be backed up, clear the app (or reinstall), restore the same key, read
  the QR again.
- **Expect:** the same `lno1…` offer both times; a payment made to it after
  the reinstall is minted by the new install.
- **How:** `android-smoke.sh` QA-118 · Guard:
  `an_offer_backup_brings_the_offer_and_its_payments_back_after_a_reinstall`,
  `wallet_offer_backups_are_sealed_to_the_account_and_survive_a_reinstall`,
  `CashuWalletEngineTest.aReinstalledWalletPublishesItsBackedUpOfferNotANewOne`,
  `CashuOfferBackupTests.testAReinstalledWalletPublishesItsBackedUpOfferNotANewOne`
- **Origin:** #614 — the offer's quote id lived only on the device, so a
  reinstall published a new offer and payments to the old one stayed at the
  mint, unclaimed.

### QA-120 — A send whose melt request is lost is never reported Failed
- **Platforms:** both (one Rust core; iOS on the fake mint through
  `scripts/qa/mint-proxy.py`; headless with `sonar-cashu-cli --mint <proxy>`)
- **Steps:** fund the wallet, get a foreign invoice from the second fake mint,
  `mint-proxy.py arm drop-melt` (the melt POST is cut off before the mint
  sees it and held), pay the invoice. Then either `mint-proxy.py deliver`
  (the request reaches the mint late and is paid) or `mint-proxy.py discard`
  (it never arrives). Repeat once with an app relaunch before `deliver`, and
  once with `deliver` only after the send reads Failed (60 s and a watcher
  pass later).
- **Expect:** while the request is out the payment reads "Taking longer than
  usual … Still in flight — held, not lost", never "Payment failed — you
  were not charged". After `deliver`: "Paid … They received N sats" within a
  watcher pass, balance down by the amount and fee, the mint's melt quote
  PAID. After `discard`: "Couldn't send … not charged" once 60 s have passed,
  balance unchanged. A relaunch in between changes nothing. A `deliver` after
  Failed is refused by the mint (HTTP 400, quote stays UNPAID), and the
  balance stays whole and spendable: the watcher spent the inputs in a swap
  to itself before it said Failed.
- **Guard:** `a_compensated_melt_the_mint_pays_late_is_pending_then_paid`,
  `a_compensated_melt_still_unpaid_after_the_grace_window_is_failed`,
  `a_melt_request_arriving_after_the_grace_window_cannot_be_paid`,
  `an_ambiguous_melt_is_still_tracked_after_a_relaunch`,
  `a_lost_melt_answer_is_pending_in_lookups_until_the_mint_answers`;
  app side `aSendReportedFailedIsPaidWhenTheWalletLaterCompletesIt`,
  `testASendReportedFailedIsPaidByALaterCompleteForItsWalletPayment`
- **Origin:** #614 review (High). CDK compensates a melt whose POST got no
  answer when the mint then reads Unpaid, and returns `PaymentFailed`, the
  same error as a real failure. With the proxy, the build before the fix said
  Failed, the mint then paid 210 sats, and the wallet kept counting them.
  A `deliver` after the grace window used to be paid too (HTTP 200, quote
  PAID) over a Failed row, with the balance still counting the spent inputs;
  that was fixed in the same PR by retiring the inputs first.

### QA-121 — A melt still on its way to the mint is left to its send
- **Platforms:** both (headless or iOS through the proxy)
- **Steps:** `mint-proxy.py arm delay-melt 12`, pay a foreign invoice.
- **Expect:** in flight for about 12 s, then paid; never Failed; the balance
  is exact afterwards.
- **Guard:** `a_pass_during_a_confirm_in_flight_leaves_that_melt_alone`
- **Origin:** #614 review. The watcher's `finalize_pending_melts` resumed
  every open melt, including one whose confirm a send was still awaiting;
  the mint read Unpaid and CDK compensated a payment it then made. End to
  end the race does not show through CDK's own HTTP client, which queued the
  watcher's status check behind the melt POST in this pass; the unit test
  against the in-process fake mint is the guard.

### QA-122 — A mint that answers after the wallet's deadline does not cut it off
- **Platforms:** both (one Rust core; iOS on the fake mint through the proxy)
- **Steps:** `mint-proxy.py arm delay-mint-answer 20` (the mint issues at once,
  its answer arrives after the wallet's 15 s deadline), then Receive → request
  an amount; the fake mint pays the invoice.
- **Expect:** "Received N sats" shows within about 20 s; the log has one
  "a mint call was abandoned mid-flight: opening a fresh connection" and no
  stream of "mint-quote poll failed … timed out" afterwards. Sends and
  receives keep working without a relaunch.
- **Guard:** `connector::tests::a_call_abandoned_mid_flight_rebuilds_the_client_once`,
  `a_mint_call_that_timed_out_is_recovered_on_the_next_pass`
- **Origin:** #614 QA pass (round 4). After one timed-out mint call every later
  request to the mint timed out, every watcher pass, until the app was
  relaunched: the HTTP client under CDK (bitreq 0.3) keeps a cached
  connection waiting forever for an answer nobody reads. The build before
  the review fixes behaves the same.

### QA-123 — An address on the old wallet moves only when the user says so
- **Platforms:** both (manual: needs an account whose handle was claimed on a
  pre-Cashu build and still has its Breez wallet, i.e. a build with a Breez
  key; the registrar's DNS TXT is readable with
  `dig TXT <name>.user._bitcoin-payment.sonarprivacy.xyz`)
- **Steps:** update such an install to this build, open it and wait for the
  wallet to come online; read the TXT record. Open Profile (and Settings,
  and the Wallet screen's old-wallet card). Tap Move to new wallet, read the
  confirmation, confirm. Read the TXT record again. Then Move back to your
  old wallet, confirm, read it once more.
- **Expect:** after the update the TXT record still carries the Breez offer
  and every surface says "Your address … still pays your old wallet." The
  confirmation says payments will go to the new wallet held as ecash at
  mint.hedwig.sh, that the old wallet stays spendable, and that deleting the
  new wallet does not move the address back. After confirming, the record
  carries the Cashu offer and the notice is gone; after moving back it
  carries the Breez offer again. A relaunch neither asks again nor
  re-registers. With the registrar unreachable the move shows its error and
  the notice stays.
- **Guard:** `WalletAppStateTest.anAddressOnTheOldWalletMovesOnlyOnAConfirmedMove`,
  `SonarHandleAddressTests.testAnAddressOnTheOldWalletMovesOnlyOnAConfirmedMove`,
  `HandleAddressTest`, `SonarHandleAddressTests.testHandleOfferActionMatrix`
- **Origin:** #614 review (H3) — once a Cashu offer existed, the descriptor
  publish re-claimed the public handle with it, retargeting its DNS record at
  the mint with no confirmation, and nothing ever wrote the Breez offer back.

### QA-124 — The fee paid never exceeds the fee shown
- **Platforms:** both (manual, fake mint: raise the fee reserve between the
  sheet's quote and Send with `mint-proxy.py arm inflate-melt-fee 40`, which
  rewrites the next melt quote's answer; unit tests drive it with a scripted
  reserve). Passed on the iOS simulator in #614 QA round 4: "up to 3 sats"
  on the sheet, refused at 40, Try again paid with a 3-sat fee.
- **Steps:** Send → paste an offer → type an amount, wait for "Network fee:
  up to N sats" → raise the reserve → Send. On the status screen tap **Try
  again**. Repeat from a chat ⚡PAY sheet; and once with the mint stopped
  while the sheet quotes (no fee line), then started before Send.
- **Expect:** nothing is sent; the payment fails with "The network fee is now
  up to M sats. Nothing was sent — try again to pay it." — on the status
  screen in place of "No route…", as a toast for a chat pay. **Try again**
  pays with M as the new ceiling (a further rise is refused again). With no
  fee on screen, any non-zero fee is refused the same way. The Send button
  is disabled while "Checking the fee…" shows.
- **Guard:** `CashuWalletEngineTest.aFeeAboveTheConsentedCeilingIsRefusedWithTheNewFeeAndNothingIsSent`,
  `WalletAppStateTest.aDestinationPaymentAboveTheConsentedFeeFailsWithTheNewFeeAndTryAgainPaysIt`,
  `WalletAppStateTest.aChatPayAboveTheConsentedFeeIsRefusedWithTheNewFee`,
  `PaySheetFeeConsentTest`,
  `CashuWalletServiceTests.testAFeeAboveTheConsentedCeilingIsRefusedWithTheNewFeeAndNothingIsSent`,
  `CashuWalletServiceTests.testADestinationPaymentAboveTheConsentedFeeFailsAndTryAgainPaysTheNewFee`,
  `CashuWalletUXTests.testTheConsentedCeilingIsTheFeeOnScreen`,
  `SonarPaymentStatusTests.testAFeeChangeIsStatedOnlyOnAFailedPayment`
- **Not covered:** the Unify nearby sheet shows no fee (its offer is read over
  BLE after Send), so a Unify send has no ceiling on either platform.
- **Origin:** #614 maintainer review — the sheet's "up to N" came from a
  discarded quote and Send re-prepared and paid whatever the new reserve was,
  checked only against the balance.

## Core test stability

### QA-125 — Account-backup unit tests are stable under parallel runs
- **Platforms:** core (both apps ship it)
- **Steps:** `scripts/qa/core-flake-check.sh --runs 20`: `sonar-core`'s lib
  suite 20 times each with default threads, `--test-threads 64` and
  `--test-threads 1`.
- **Expect:** 0 failed runs in every mode.
- **Guard:** `a_fresh_process_for_one_account_leaves_another_seal_in_flight`
- **Origin:** #614 QA. Two account-backup tests failed once in a workspace run
  on a loaded Mac and passed on rerun. A test simulating a fresh process
  cleared the whole process-wide policy cache; running in parallel, that
  dropped other tests' in-flight seal fingerprints between their seal and
  `record_backup_success`, so their next identical seal was not skipped. At
  `--test-threads 64`, 9 of 40 runs of the backup tests failed, across five
  tests. The clock was not involved: the unchanged-backup window is 7 days.

## Open questions (need a product decision, not a fix)

- **Data usage (A24):** "Wi-Fi only" is stored but nothing reads it on either
  app, and the defaults differ (iOS Wi-Fi only, Android Always). Enforce it
  (gate media auto-download on metered links) or remove it.
- **Bitcoin mode default (A23):** both apps default to sats; the old copy
  claimed fiat. Which one is intended?
  Note (#614): on iOS the SDK fallback is sats, but the app picks fiat in the
  locale currency on first run (`applyFirstRunMoneyDefaults` before #614,
  `SonarMoneyDisplay` after), so a fresh iOS install shows fiat.

- **Fingerprint card (A3/A6):** iOS shows the Noise (mesh) key fingerprint,
  Android the nsec pubkey fingerprint — people comparing in person across
  platforms never match. Android also shows "Generating…" on the onboarding
  done step because the nsec is created on *Start chatting*.
- **Exact "send all" (#618):** Max leaves the mint's unused fee reserve as
  change (5 sats in the #614 live test). A mint-side zero reserve for same-mint
  payments is under discussion (cashubtc/cdk#2606).
