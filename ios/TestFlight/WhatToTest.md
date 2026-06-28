# TestFlight — What to Test

Build: **Sonar 1.6.0 (3)**

This build is mostly about **stability and offline payments**. It fixes the two
top TestFlight crashes (app getting killed while locked/backgrounded) and makes
paying a peer who is currently offline actually work. The payment, media, and
GIF features from the previous build are still here — please give them a quick
regression pass too.

If something crashes on launch, while locked, or right after sending money,
that is the highest-priority report.

## 1. Background / locked stability (top crash fixes)

Previous builds were killed by iOS when the screen locked or the app went to
the background during chat or wallet activity. This should no longer happen.

- Open a chat, then **lock the phone** for 30–60s and unlock — confirm the app
  is still running (not relaunched) and the chat is intact.
- Send or receive a **payment**, then immediately **lock the phone** or switch
  to another app for a minute. Come back and confirm no crash and the payment
  state is correct.
- Leave the app **backgrounded for several minutes** with the phone locked,
  then reopen — confirm it resumes instead of cold-launching/crashing.
- After updating to this build, confirm your **identity, nickname, contacts,
  and wallet balance survive** the upgrade.

## 2. Offline payments (pay a peer who isn't online)

You can now pay a peer even when their app is closed/backgrounded — they get
woken via push to receive.

- Pay a peer who has a **payment address** set but whose app is **closed or
  backgrounded**. Confirm your bubble moves **sending → paid** and does not get
  stuck or fail with a raw error.
- On the **receiving** device (the offline one), confirm a notification/wake
  arrives and the incoming payment shows up as pending/paid after settling.
- Try a normal **both-online** payment too and confirm it still works.

## 3. Notifications

Notifications are now generated with useful content.

- With the app **backgrounded**, receive a **message** and a **payment** and
  confirm the notifications are **meaningful** (who it's from / what it is), not
  generic placeholders.
- Check **Settings** for the notification **privacy** option and confirm
  toggling it changes how much detail appears on the lock screen.

## 4. Your payment address stays payable

Your published payment address (BOLT12 offer) should no longer get wiped when
your profile/presence republishes.

- Set a **Payment address (BIP-353 / BOLT12)** in Settings.
- Change your **nickname** / reconnect / move in and out of range so your
  profile republishes, then have **another peer pay you**. Confirm you are
  still payable (the address wasn't cleared).

## Regression pass (from the previous build)

- **Direct wallet payments**: gold payment bubble appears immediately; activity
  list shows newest first with amount, peer, rail, fee, status. Paying a peer
  with **no** payment address is blocked, not a crash.
- **Media**: send/receive a photo, tap to open fullscreen, **save** it, and
  confirm the file opens intact.
- **GIFs / emoji**: an animated GIF **animates** in the chat (not a frozen
  frame); a regular photo is not mislabeled as a GIF; the emoji tray works.

## Known gaps

- New payment/onboarding/safety-number strings are **English-only**; other
  languages fall back to English. That is expected, not a bug.
