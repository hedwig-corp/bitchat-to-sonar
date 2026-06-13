# Sonar Mock-Removal Plan (2026-06-13)

Goal: nothing fake is reachable in the running app. The Sonar UI
(`bitchat/Views/Sonar/`) keeps the design-handoff visuals 1:1, but every
value rendered now comes from the real services:

- `ChatViewModel` — BLE mesh timeline, geohash channels, private chats,
  nickname, fingerprints, panic wipe
- `LocationStateManager` — location channel levels + humanized names
- `GeohashParticipantTracker` (via ChatViewModel) — per-geohash counts
- `UnifiedPeerService` — peers, connectivity tiers, mutual favorites
- `MessageRouter` — mesh vs NIP-17 DM routing (untouched, reused)
- `NostrRelayManager` — online state, relay count
- `MarmotChatModel` / `MarmotService` — White Noise (MLS over Nostr) chats

## Status legend

- **REMOVED NOW** — the mock is gone from the app; real data replaced it.
- **HIDDEN** — the prototype UI row had no real backend; it is not rendered.
  Showing a fake switch would be a mock, so hiding is the correct removal.
  Each entry lists what is needed to unhide it.
- **KEPT** — not a mock (design copy / inert chrome), kept deliberately.
- **KEPT-INTERNAL** — compiles but is unreachable from the app root.

## Inventory

| # | Mock/demo artifact (prototype) | Status | Replacement / what is needed |
|---|---|---|---|
| 1 | `SonarDemoData.swift` (data.js transcription) | **REMOVED NOW** | File deleted. `SNMessage`/`SNVia` moved into `SonarAppStore.swift`; no SwiftUI preview depended on it. |
| 2 | Fake peers Maya / Luca / nettle / koi_ / Sofia / Tomas | **REMOVED NOW** | Radar/list/compose/DM rows come from `UnifiedPeerService` (`allPeers`): connected → inner ring, mesh-relayed → middle ring, unreachable mutual favorites → outer-ring internet ghosts. Deterministic angles from FNV-1a of the peer ID. |
| 3 | Demo channels "Lugano · Centro" / "Lugano" (fixed counts 12/48) | **REMOVED NOW** | Home shows `#mesh` (real mesh peer count) + `LocationStateManager.availableChannels` with humanized `locationNames[level]` and `geohashParticipantCount(for:)`. Permission-gated row prompts to enable location. |
| 4 | Demo transcripts (`chMsgs`, `dmMsgs`, `dmMsgsSofia`) | **REMOVED NOW** | Channel = `ChatViewModel.messages` for the selected channel; DM = `privateChats[peerID]`; Marmot = `messagesByGroup[groupId]` (5 s polling while the screen is open). Sends go through `sendMessage` / `sendPrivateMessage` / `MarmotChatModel.send` — no new send paths. |
| 5 | Fake safety numbers (`safety` array) | **REMOVED NOW** | 12 five-digit groups derived deterministically (order-independent) from both parties' real key material: Noise fingerprints (mesh) or npubs (Marmot). Honest "connect over Bluetooth first" state when no peer fingerprint exists yet. |
| 6 | Demo npub `npub1w4j8…` + demo fingerprint `a3f9 2c41 770e 5b2d` | **REMOVED NOW** | Real Marmot identity npub (placeholder "npub · connecting…" until the service connects); fingerprint = real Noise identity fingerprint (`getMyFingerprint()`), formatted in 4-char groups. |
| 7 | Fake network toggle (chip + Settings "Connection" flipped a pretend network) | **REMOVED NOW** | **Decision:** the chip stays informational and animated per design — Online = `NostrRelayManager.isConnected`, mesh count = connected/reachable peers. Tapping it (and the Settings Connection row) opens a small connectivity sheet with real facts (relay count, people in range). Toggling Nostr manually would fight `NetworkActivationService`'s policy engine, so no toggle. |
| 8 | Demo persistence blob `sn_proto_v1` | **REMOVED NOW** | Deleted from UserDefaults on launch. New keys: `sonar.onboarding.complete` (gate), `sonar.appearance.mode`, `sonar.verified.marmot`. |
| 9 | Fake read map / fake unread badges | **REMOVED NOW** | DM unread = `ChatViewModel.unreadPrivateMessages` (cleared by the real `startPrivateChat`). Channels show no fabricated unread counts. |
| 10 | Fake "verified" map | **REMOVED NOW** | Mesh peers: `ChatViewModel.verifyFingerprint(for:)` + `verifiedFingerprints` (keychain-backed via `SecureIdentityStateManager`). Marmot chats: local persisted marks (`sonar.verified.marmot`) until MDK exposes member-key verification. |
| 11 | Settings: App lock toggle | **HIDDEN** | Needs a LocalAuthentication (Face ID) gate at app foreground. |
| 12 | Settings: Read receipts toggle | **HIDDEN** | Read receipts are always sent by `PrivateChatManager`; needs a real pref the manager consults before unhiding. |
| 13 | Settings: Message requests (fake "driftwood" request) | **HIDDEN** | Needs a real message-request queue (unknown-sender gating) in the chat pipeline. |
| 14 | Settings: App icon picker (Cyan/Midnight/Paper) | **HIDDEN** | No `CFBundleAlternateIcons` registered. Register alternate icons + `setAlternateIconName` to unhide. |
| 15 | Settings: Notifications sheet (allow / show names / preview toggles) | **HIDDEN** | No real prefs exist; `NotificationService` ignores them. Add prefs it consults (and reflect UNAuthorizationStatus) to unhide. |
| 16 | Settings: Data & storage ("124 MB", "Wi-Fi only") | **HIDDEN** | Fabricated numbers. Needs real storage measurement / data-usage policy. |
| 17 | Settings: Help row | **HIDDEN** | No destination. Needs a real help URL/screen. |
| 18 | Composer "+" sheet: "Share location" row | **HIDDEN** | Needs a real location-share message type over mesh/Nostr. ("People nearby" kept — it opens the real radar.) |
| 19 | Composer "+" sheet: "Reactions" row | **HIDDEN** | Needs a real reaction message type. ("Verify safety number" kept — real data.) |
| 20 | `/slap`, `/who`, `/msg` commands | **REMOVED NOW** (de-mocked) | `/slap` posts the action line through the real channel/DM send path (target = most recent other participant); `/who` and `/msg` push the real Nearby screen, per design. |
| 21 | Onboarding nickname suggestions ("quietfox", …) | **KEPT** | Design copy from data.js, not demo data: "Surprise me" assigns the user's *real* nickname (saved via `validateAndSaveNickname`). Moved into `SonarOnboardingScreen.swift`. |
| 22 | Home "Search" pill (was a no-op in the prototype) | **KEPT (inert)** | Visual design chrome with no fake data. Follow-up: wire to real message/people search; removal would change the design, which is out of scope for this pass. |
| 23 | `SNShareCode` QR-style code | **KEPT** | Now seeded from the real npub/fingerprint, but it is a decorative deterministic pattern from the design, not a scannable QR. Follow-up: render `VerificationService.buildMyQRString` as a real QR. |
| 24 | Emergency wipe (was a state reset) | **REMOVED NOW** (de-mocked) | Calls the real `ChatViewModel.panicClearAllData()` (all keychain data incl. `marmot-nsec`, messages, favorites, verified set, nickname), explicitly deletes the `marmot-nsec` identity key, resets the in-memory Marmot model and the Sonar UI state, returns to onboarding. |
| 25 | Legacy unreachable views: `ContentView`, `MarmotChatView` (view), `SonarNearbyView`, `SonarOnboardingView`, `Components/SonarMessageBubbleView`, `Components/SonarStatusChip`, `MeshPeerList`, `VerificationViews`, … | **KEPT-INTERNAL** | Still compile, unreachable from `SonarRootView`. `MarmotChatModel` (in MarmotChatView.swift) is reused by the live store. Follow-up: delete the dead view bodies once the Sonar UI covers their remaining features (QR verify, location notes, media). |

## Known limitations / follow-ups to reach 100 %

- **Per-message transport tags:** `BitchatMessage` has no per-message
  transport field; own-bubble color and via-icons use the *current* route
  (geohash ⇒ internet, mesh reachability check otherwise) exactly like the
  prior `SonarMessageBubbleView`. A persisted per-message transport needs a
  model change in the bitchat core.
- **Marmot wipe depth:** the Rust core keeps the in-memory MLS state until
  process exit; keys are gone from the keychain, and a fresh identity is
  generated on next launch. A `reset()` API on `MarmotService` would make
  wipe immediate.
- **Marmot verified marks** are device-local; real MLS member-credential
  verification should replace them.
- **Channel history:** geohash channels show messages received since
  subscribe (kind-20000 is ephemeral); mesh shows the session timeline.
  This matches bitchat behavior, not a regression.
