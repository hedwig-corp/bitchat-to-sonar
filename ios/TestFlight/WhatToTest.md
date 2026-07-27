# TestFlight — What to Test

Build: **Sonar 1.12.4 (32)** · Apple hotfix on **v0.1-alpha.12** (+ #441–#461 stack)

Hotfix over 1.12.3: chat open/unread divider (#441), bitcoin payment option
(#442), nearby peer flapping (#444), share-sheet recipient pick (#447), keep
backgrounded Marmot store closed (#459), username claim UI (#460), and calm the
relay-connect banner when chat already works (#461). Opening a chat should
still paint from local storage first; missed messages catch up in the
background; payments and notifications should stay stable when the phone is
locked or the app is killed.

If something crashes on launch, while locked, or right after sending a message,
photo, or payment — that is the highest-priority report. If sync feels slow or
a message is missing, use **Settings → Diagnostics → Share** and send us the
log.

## 1. Sync speed & catching up (headline)

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
- On Android/desktop: after a welcome creates a group or a live event arrives,
  the open chat / list should refresh within seconds without a manual pull.

## 2. Home list & conversation correctness

- Home / Messages should order by **latest activity across transports** (mesh +
  relay), not leave a busy chat buried under an idle one.
- A peer you talk to over **mesh and Sonar/relay** is **one conversation**, not
  two rows. Moving in/out of BLE range must not create a duplicate pubkey chat.
- Peer **nickname changes** should update list + transcript (not stick on the
  old name or a raw key).
- You should **not** get spammy system “reconnected” alerts when BLE flaps.

## 3. Multi-photo & media

- Send **multiple photos** in one go: the transcript should show an album-style
  card deck (xChat-style), not only a single image bubble.
- Open the album / individual photos fullscreen; confirm save still works.
- Animated GIFs still **animate** (not a frozen frame).
- Stickers still send/receive (sticker kinds were moved to 30031/10031 — old
  packs may need a re-publish if something looks empty).
- Reopen a chat with stickers / attachments: previews should appear from
  **local cache** immediately, not wait on Blossom/network.
- In a **folded** mesh+relay chat, scroll up to load older history — older
  pages must keep loading (not stop after the first window).

## 4. Stability / crash fixes

- Mixed content (emoji, long text, links, reactions) renders without crashing.
- Open a chat, **lock the phone** 30–60s, unlock — app should still be running
  and the chat intact (no 0xdead10cc / cold relaunch from wallet work).
- Send or receive a **payment**, then immediately lock or background for a
  minute. Come back: no crash, correct payment state.
- Leave the app backgrounded several minutes locked, then reopen — resume, not
  crash-loop.

## 5. Wallet & offline payments

- After update: **identity, nickname, contacts, and wallet balance** survive.
- Published **BOLT12 offer / payment address** still set; you remain payable
  after reconnect / rename (offer must not get wiped by a later publish).
- **Offline payments**: pay a peer whose app is closed/backgrounded; your
  bubble moves sending → paid; they get woken to receive.
- Direct wallet payments: gold payment bubble appears immediately; activity
  list newest-first with amount, peer, rail, fee, status. Paying a peer with
  **no** payment address is blocked, not a crash.

## 6. Notifications

- App backgrounded: message and payment produce **meaningful** notifications
  (who/what), not generic placeholders; privacy toggle changes lock-screen
  detail.
- Push wake / foreground should kick Marmot relay sync so chats catch up after
  a notification.

## 7. Diagnostics (please use this)

- **Settings → Diagnostics → Share** exports a log.
- Try verbose + privacy/redaction levels; confirm a shareable file is produced.
- After slow sync, missing message, or crash: export **right away** and attach
  to the report.

## 8. Account key durability

- Updating must **not** mint a new account / nsec. If prefs are lost but the
  keychain key remains, you should recover into the same account, not onboarding.

## 8b. Restore account (nsec)

- Fresh install: onboarding shows a clear **Restore account with private key**
  button (not easy to miss). Paste a valid `nsec1…` → same identity + wallet
  balance after Breez sync. If you previously used **Backup chats**, Marmot
  history comes back from Blossom; otherwise local chats start empty.
- Settings → **Backup chats**: uploads an encrypted Marmot backup (needs
  network). Settings → **Restore account**: replace the current account with a
  pasted nsec; confirm wipe; wallet rebuilds from that key; chats restore from
  Blossom when a backup exists.
- Invalid nsec shows an error and does not corrupt the current account.

## Regression pass (still expected)

- Group invite links (QR / share / paste / join).
- Calls: mute icon/label correct, hang-up dismisses immediately, no phantom
  missed-call rows.
- Voice notes play on the platform you test (iOS / Android / desktop).
- Profile edit on iOS matches Compose (name / photo) where parity shipped.

## Known gaps

- Some newer payment/onboarding/safety-number strings are **English-only**;
  other languages fall back to English — expected, not a bug.
- In-app QR camera scanning may still be limited; paste/share links work.
- Archive for this cut was verified as a valid **iOS App Archive** (single
  `Sonar.app`, both extensions in `PlugIns`, `ApplicationProperties` present).
  TestFlight upload still needs App Store Connect distribution signing via
  Xcode Organizer / `xcodebuild -exportArchive`.
