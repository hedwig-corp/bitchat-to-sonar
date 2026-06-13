# Sonar on-device demo & interop test plan

Target: Sonar build running on Vincenzo's iPhone, verified against stock
bitchat and White Noise. Run the suites in order — each builds on the last.

## 0. Install

1. Connect the iPhone, open `bitchat.xcodeproj` in Xcode, select the
   `bitchat (iOS)` scheme and your personal team under Signing & Capabilities
   (or build from CLI: see "Device build" in CLAUDE.md learnings).
2. First launch: complete onboarding, grant Bluetooth + notification
   permissions. Expected: Sonar branding, dark-cyan theme.

## Suite A — bitchat ↔ Sonar (wire compat must be untouched)

Second device: stock bitchat from the App Store (or another dev build of
upstream `permissionlesstech/bitchat`).

- A1 BLE discovery: airplane mode BOTH devices (Wi-Fi/BT on). Sonar's Nearby
  radar shows the bitchat peer within ~10–30 s; bitchat sees Sonar's nickname.
- A2 Mesh DM bitchat → Sonar: send a private message from bitchat. Expected on
  Sonar: message arrives, own replies render CYAN (mesh transport).
- A3 Mesh DM Sonar → bitchat: reply. Expected: arrives in bitchat, encrypted
  (Noise), delivery ack/read receipt still work.
- A4 Nearby/geohash channel: both devices online, same location channel.
  Messages flow both ways; Sonar shows humanized place name, never the raw
  geohash as the primary label.
- A5 Nostr fallback: separate the devices (BLE out of range), mutual
  favorites set. DM Sonar → bitchat. Expected: delivered over Nostr (NIP-17);
  Sonar's own bubble renders INDIGO (internet transport).

## Suite B — White Noise ↔ Sonar (Marmot/MLS)

Second device/user: White Noise app (marmot-protocol/whitenoise releases),
logged in with a Nostr identity.

- B1 Sonar identity: in Sonar, confirm npub exists (settings/profile);
  publish KeyPackage (happens on Marmot connect).
- B2 Sonar → White Noise: start a Marmot DM with the White Noise user's npub.
  Expected: White Noise shows the group invite/welcome; messages from Sonar
  decrypt; replies arrive in Sonar after sync.
- B3 White Noise → Sonar: the White Noise user starts the chat instead
  (requires Sonar's KeyPackage to be on shared relays — B1 first). Sonar
  auto-accepts the welcome on sync and shows the message.
- B4 Bidirectional ping-pong: 5 messages each way; verify ordering, no
  duplicates after repeated sync.

## Suite C — regression sweep

- C1 Triple-tap emergency wipe still clears everything.
- C2 Tor toggle (if enabled) still routes Nostr traffic.
- C3 Light AND dark mode render correctly (token pairs).
- C4 Reduce Motion: radar sweep/pulse animations disabled.

## Known M1 limitations (expected, not bugs)

- Marmot state is in-memory: a Sonar restart loses Marmot groups (sqlite
  storage is M2 work). Re-running B2 after restart needs a fresh DM.
- Marmot sync is poll-based (no live subscription yet) — pull-to-refresh or
  reopening the chat triggers sync.
- Welcomes are auto-accepted (no invite UX yet).

## Results log

| Test | Date | Result | Notes |
|------|------|--------|-------|
| A1   |      |        |       |
| A2   |      |        |       |
| A3   |      |        |       |
| A4   |      |        |       |
| A5   |      |        |       |
| B1   |      |        |       |
| B2   |      |        |       |
| B3   |      |        |       |
| B4   |      |        |       |
| C1–C4|      |        |       |
