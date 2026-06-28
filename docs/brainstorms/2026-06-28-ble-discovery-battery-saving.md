## Clarified Problem Statement

**Goal:** Let users disable open BLE discovery, and automatically restrict BLE discovery during battery saving so Sonar only reconnects peers that already have a local chat.

**Constraints:**
- Ship on Apple (`ios/`) and Compose Multiplatform (`apps/sonar/`) together.
- Preserve local-first chat paint; the policy must not add relay waits or transcript scans before opening chats.
- Keep BLE advertisements protocol-compatible and avoid adding stable identifiers to public advertisements.
- Stop extra new-peer discovery work, including Unify nearby scans, while restricted.

**Non-goals:**
- Do not remove BLE mesh messaging for existing chats.
- Do not change Marmot/Nostr descriptor discovery.
- Do not add pairwise BLE contact tokens in this slice.

**Success Criteria:**
- Settings exposes a "Discover new people" control.
- iOS Low Power Mode and Android Battery Saver force "chats only" BLE discovery.
- Restricted mode keeps local conversations visible and filters Radar to already-chat peers.
- Unify payment-only nearby discovery is stopped while restricted.
- Desktop's missing OS battery-saver signal is documented; the manual setting still works.

## Approach B: Known-Contacts-Only Policy

- Add a BLE discovery mode with `normal` and `knownOnly` behavior.
- Keep local persisted mesh/Marmot chat state as the known-contact source.
- In `knownOnly`, continue enough BLE radio work to reconnect known chats, but reject verified announces from peers that do not map to a local conversation.
- Use lower-power Android scan/advertise settings while restricted.
- Keep iOS protocol-compatible: because advertisements intentionally do not expose stable peer IDs, iOS may briefly connect to verify identity before dropping unknown peers.

## Implementation Plan

- Apple:
  - Add `BLEDiscoveryMode` and known-peer provider hooks to `BLEService`.
  - Gate peer acceptance after signed announce verification.
  - Store an app-maintained known-chat key snapshot in `UserDefaults` for thread-safe BLE reads.
  - Add iOS Low Power Mode observer in `SonarAppStore`.
  - Add Settings and Radar status copy.
- Compose:
  - Add common `BleDiscoveryMode` plus `BatterySaver` expect/actual.
  - Enforce known-only filtering in Android and Desktop `MeshRadio`.
  - Use Android `PowerManager.isPowerSaveMode`.
  - Add Settings and Radar status copy.
- Docs:
  - Document the restricted policy and the iOS/Desktop limitations in `docs/SONAR-DISCOVERY.md`.
