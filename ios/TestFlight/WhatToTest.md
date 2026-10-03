# TestFlight — What to Test

Build: **Sonar 1.15.4 (49)** · **v0.1-alpha.15.4** (Android 0.1-alpha.15.4, code 27)

Point release on alpha.15. **Headline: going from offline to online no
longer freezes the app (#656, #657, #659).** The effect is biggest on
accounts with hundreds of chats.

## 0. Offline → online without freezing (headline, iOS)

Three things blocked the screen or the catch-up when the app came back:
- recomputing every chat's local-time setting on the way into the
  foreground (#656);
- looking up every chat's mute state each time the chat list rebuilt (#659);
- profile lookups and push-token messages queued ahead of the catch-up (#657).

- Switch on airplane mode (or leave Sonar in the background) for a few
  minutes, then come back. While it catches up, scroll the chat list and open
  a chat straight away. It should stay smooth, with no one-second hitches.
- Mute one chat first if you can. With nothing muted the app now skips that
  lookup entirely, so a muted chat is what exercises the fixed path.
- Messages that arrived while you were away should show up within a few
  seconds, even with many chats.
- If it still stutters: **Settings → Diagnostics → Share** right away.

## 0a. Fewer background messages to your contacts (#657, iOS + Android)

Sonar tells the people you chat with how to wake your phone for new
messages. It used to resend that to everyone on every sync, which on a big
account was hundreds of relay messages each time. It now goes to each person
once, in small batches, and again only when your notification token changes.

- Nothing to tap. Check that a message from someone you have not talked to in
  a while still produces a notification while Sonar is closed.

## 0b. Messages missed while you were away (from 1.15.3, #649)

- Send a message in a chat, then leave Sonar in the background (or switch off
  data) for more than 30 minutes while the other person replies.
- Open Sonar for about 15 seconds **without** opening that chat. The reply
  should already be in the chat row and in the transcript.

## 0c. Local time in chats (from 1.15.2, #644)

- With **Settings → Privacy & safety → Share local time** on, ask a contact
  on 1.15.2+ (or Android 0.1-alpha.15.3+) to open your chat. Their header
  should show your time (`10:48 PM`, plus `· N hours ahead/behind` if you are
  in different zones).
- If a header still shows "Via internet" / "Nearby · Bluetooth" after a
  minute, send **Settings → Diagnostics → Share** from **both** phones.

## 0d. Launch speed (from 1.15.1, #629)

- Kill the app, reopen it. Home should show your chats within a couple of
  seconds, not sit empty while the network thrashes.
- Leave it in the foreground a minute. It must **not** keep republishing
  (no stuck “syncing”, no flood of identical system activity).
- Background, lock 30–60s, unlock. Chats and unread counts are still there.
- If you had an empty home on 1.15.0, this build should fill it from local
  storage without a reinstall.

## 1. Cashu wallet

- Updating from 1.14.x: **identity, nickname, contacts survive** and the
  wallet comes up as **Cashu** — balance visible in sats (USD where shown).
- Mint offline: the app retries the mint quietly in the background; no stuck
  “connecting” state, no crash, and it recovers when the mint is reachable.
- Send and receive a payment in a chat: the bubble moves sending → paid;
  activity list newest-first with amount, peer, rail, fee, status.
- **Offer backup / restore**: reinstall the app, restore the account — the
  wallet **re-publishes its backed-up offer / payment address, not a brand-new
  one**, so a peer holding your old address can still pay you.
- Paying a peer with **no** published payment address is blocked, not a crash.
- A nearby **Unify send shows its amount and fee before you pay**.
- Legacy Breez: if you used the old wallet before this update, confirm the
  old balance/identity survived or migrated as expected — report anything
  that looks wrong either way.

## 2. Reactions (new)

- Long-press a message → reaction picker; pick an emoji → a chip appears on
  the bubble, and the peer sees the same reaction.
- Add a second reaction, change it, remove it — state agrees on both devices
  and after reopening the chat.
- Mixed content (emoji, long text, links) **with reactions** renders without
  crashing, including in short chats opened with the keyboard up.

## 3. Private local time (new, #607)

- In an encrypted chat, message times reflect your local time; a peer sees a
  time, not your raw timezone leak beyond what the setting allows.
- Settings can **revoke local time** — after revoking, timestamps stop
  exposing it; the toggle has a proper accessibility label.

## 4. Note to Self (new)

- Home always carries your pinned **Note to Self** — a solo chat that is
  **local-only**: nothing is relayed to peers.
- Write, edit and delete notes; **no peer or group actions** inside it (no
  invites, no member list).
- Delete it from its row → it comes back later, **empty**, still pinned.

## 5. Share extension (iOS)

- Share a **document** (pdf/zip) from another app into Sonar: the peer
  receives the **actual file**, not a path, and can open it.
- Sharing a **directory** is refused cleanly — no recursive-copy hang.
- The chat offers the share you just made; a document is **never sent twice**.
- Cold-share: accept a share while Sonar is fully closed — the chat opens with
  the pending share intact (QA-092).

## 6. Sync speed & catching up

Missed messages should arrive quickly on wake/foreground, and one chat’s
activity must never hold back another’s resync.

- Leave the app **closed/backgrounded**, have a peer send several messages,
  then **open the app**. Confirm missed messages appear promptly without a
  stuck “syncing” state.
- Open an existing chat: it should **paint instantly from local history** and
  fill gaps in the background — not blank/spinner while talking to relays.
- Send in one chat, then open a **different** chat that still has older
  unreceived peer messages. The second chat must still pull the missing ones
  (a newer send elsewhere must not skip them).
- Fire several messages in a row; sending stays snappy and is not blocked
  behind background sync.

## 7. Home list & conversation correctness

- Home / Messages should order by **latest activity across transports** (mesh +
  relay), not leave a busy chat buried under an idle one.
- A peer you talk to over **mesh and Sonar/relay** is **one conversation**, not
  two rows. Moving in/out of BLE range must not create a duplicate pubkey chat.
- Peer **nickname changes** should update list + transcript (not stick on the
  old name or a raw key).
- You should **not** get spammy system “reconnected” alerts when BLE flaps.
- A chat row whose cell kind changes (e.g. gains a reaction) **reloads** —
  no stale half-rendered bubble.

## 8. Media

- Send **multiple photos** in one go: the transcript shows an album-style card
  deck (xChat-style), not only a single image bubble.
- Open the album / individual photos fullscreen; confirm save still works.
- Animated GIFs still **animate** (not a frozen frame).
- Reopen a chat with stickers / attachments: previews appear from **local
  cache** immediately, not waiting on the network.

## 9. Stability / crash fixes

- Mixed content (emoji, long text, links, reactions) renders without crashing.
- Open a chat, **lock the phone** 30–60s, unlock — app should still be running
  and the chat intact.
- Send or receive a **payment**, then immediately lock or background for a
  minute. Come back: no crash, correct payment state.
- Leave the app backgrounded several minutes locked, then reopen — resume, not
  crash-loop.

## 10. Notifications

- App backgrounded: message and payment produce **meaningful** notifications
  (who/what) — the undecorated generic placeholders are silenced (#604);
  privacy toggle changes lock-screen detail.
- Push wake / foreground should kick Marmot relay sync so chats catch up after
  a notification.

## 11. Diagnostics (please use this)

- **Settings → Diagnostics → Share** exports a log.
- Try verbose + privacy/redaction levels; confirm a shareable file is produced.
- After slow sync, missing message, or crash: export **right away** and attach
  to the report.

## 12. Account key durability & restore

- Updating must **not** mint a new account / nsec. If prefs are lost but the
  keychain key remains, you should recover into the same account, not
  onboarding.
- Fresh install: onboarding shows a clear **Restore account with private key**
  button. Paste a valid `nsec1…` → same identity, and the **Cashu wallet
  rebuilds from that key**; if you previously used **Backup chats**, Marmot
  history comes back from Blossom.
- Settings → **Backup chats** uploads an encrypted Marmot backup (needs
  network). Invalid nsec shows an error and does not corrupt the current
  account.

## Regression pass (still expected)

- Group invite links (QR / share / paste / join).
- Calls: mute icon/label correct, hang-up dismisses immediately, no phantom
  missed-call rows.
- Voice notes play on the platform you test (iOS / Android / desktop).
- Profile edit on iOS matches Compose (name / photo) where parity shipped.
- Multi-line composer grows as you type and collapses again when cleared.
- With VoiceOver on, the chat and header buttons carry proper labels.

## Known gaps

- Some newer payment/onboarding/safety-number strings are **English-only**;
  other languages fall back to English — expected, not a bug.
- In-app QR camera scanning may still be limited; paste/share links work.
- The Cashu migration keeps Breez as the legacy rail: peers on older builds
  may still be reachable over it; flag anything that looks like a lost
  balance rather than a display lag.
- Archive for this cut must be verified as a valid **iOS App Archive** (single
  `Sonar.app`, both extensions in `PlugIns`, `ApplicationProperties` present).
  TestFlight upload still needs App Store Connect distribution signing via
  Xcode Organizer / `xcodebuild -exportArchive`.
