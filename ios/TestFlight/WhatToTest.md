# TestFlight — What to Test

Build scope: everything new on `main` since `v0.0.1-alpha.3`, plus the iOS/macOS
archive-packaging fix that produces this build (`Sonar.app` scheme + rebuilt
`sonarffi.xcframework`).

Focus your testing on the three new features below. If something crashes on
launch or right after sending money, that is the highest-priority report.

## 1. Direct Sonar wallet payments (new send path)

You now pay a peer's published wallet destination directly — no "tap to claim"
step for new-client sends.

- Set up your wallet, then open Settings and add a **Payment address (BIP-353 /
  BOLT12)**. Confirm it announces to nearby Sonar peers, and that leaving it
  empty announces nothing.
- Open a chat with a peer who has a payment address and send an amount.
  - Verify a **gold payment bubble** appears immediately in the chat.
  - Verify the bubble state line moves through **sending → paid** (or
    **failed**, with a readable reason — not a stack trace).
- Open the wallet sheet and confirm the payment shows in **activity, newest
  first**, with amount, peer name, rail, fee, and status.
- Try paying a peer who has **no** payment address — sending should be
  unavailable/blocked, not crash.
- Currency: confirm "Set up your wallet to choose a currency" appears before
  setup and that the chosen currency renders amounts correctly.
- Legacy compatibility: if you have access to an older Sonar build, confirm an
  old-style claimable ⚡PAY message from it still works on this build.

## 2. Interactive media attachments

- Send and receive a photo in a chat. **Tap it** to open the fullscreen viewer.
- In the viewer, **save** the media and confirm the file lands in Photos/Files
  intact (open it again to confirm bytes are preserved, not blank/corrupt).
- Dismiss the fullscreen viewer and confirm you return to the chat cleanly.

## 3. Animated GIF previews + emoji tray

- Send/receive an animated **GIF** and confirm the preview **animates** in the
  chat (not a frozen first frame).
- Send a regular **photo** and confirm it is NOT mislabeled/animated as a GIF.
- Open the **emoji tray** and confirm picking emoji works in the composer.

## Build/install smoke test (because this build fixed packaging)

- App installs and launches from TestFlight without an immediate crash.
- Existing identity, nickname, contacts, and wallet balance survive the update.
- Bluetooth nearby presence and an existing DM still work after upgrading.

## Known gaps / not-yet-translated

- The new payment/onboarding/safety-number strings ship **English-only**; other
  languages fall back to English. Non-English UI showing English here is
  expected, not a bug.
