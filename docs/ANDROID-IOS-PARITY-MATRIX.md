# Android ↔ iOS Parity Matrix

Date: 2026-07-05. Produced by a six-agent parallel audit (messaging/delivery,
payments/wallet, calls, media/UX, iOS drift since 2026-06-27, unmerged branch
triage). iOS (`ios/bitchat/`) is the reference; Compose (`apps/sonar/`) is the
audit target. Supersedes the gap claims in
`docs/ANDROID-IOS-PARITY-DELIVERY-PLAN.md` (slices 1–4 confirmed closed by
PR #140; Slice 5 partially closed).

Classification: PARITY (equivalent), PARTIAL (present but diverges), GAP
(missing on one surface), PLATFORM-GAP (documented platform limitation, no fix
required or possible).

Line numbers are point-in-time (2026-07-05); verify before editing. Regenerate
(or amend the affected rows) on each parity PR so this stays the single source
of truth for gap status.

## Status update (2026-07-05, PR #168 second batch)

The gap rows below marked **GAP** in §2–§4 were closed on the PR #168 branch:
payment activity ledger + wallet-incoming events, offline-push cherry-picks
(#148 commits), video call enable + camera flip + voice proximity, iOS
contact-profile favorite/block/delete + blocked gating, media caption field
(both models). Still open after this batch: partial-delivery producer (mesh
tracker), Android local camera frames + remote video frames (core gap, same
as iOS), iOS Marmot transcript re-filtering on block (pre-existing),
CallKit/ConnectionService (both platforms, tracked follow-up), and all
hardware-gated device smoke.

## Verdict summary

- **iOS drift since 2026-06-27:** clean — every user-facing commit is mirrored
  or core-owned (`SonarNode.connect()` path). Account Key Durability Rule
  invariants hold on both surfaces (#158).
- **Branch triage:** `codex/android-ios-parity-slash-commands`,
  `codex/android-parity-delivery`, `codex/media-interactions-parity`,
  `claude/android-relay-thrash-parity`, `android-ios-parity` are fully merged —
  safe to delete. `codex/android-offline-push-parity` (closed PR #148) has
  unmerged value: push-prefs centralization (`SonarPushPrefs.kt`) + killed-app
  transponder wakeup detection; cherry-pick candidates `8ca9af8f`, `fe2bc048`,
  `0e4aeea1`.
- **Largest gap surface: calls** (Compose misses iOS's incoming-offer safety
  machinery and video-call UI).
- **Largest single gap: payments** — Compose has no direct wallet payment
  activity ledger (`SonarPaymentActivityLedger` equivalent).

## 1. Messaging & delivery

| Feature | iOS (file:line) | Compose status | Classification | Size | Notes |
|---------|-----------------|----------------|-----------------|------|-------|
| Delivery status states & copy | `SonarAppStore.swift:5480-5490` `stateText()` | `SonarDeliveryText.kt:1-25` | PARITY | S | Compose adds "Uploading" for media |
| Partial delivery label ("Delivered to X of Y") | `SonarAppStore.swift:5487` | MISSING in `SonarDeliveryText.kt` | **GAP** | S | Group partial-success state renders wrong on Compose |
| Marmot resync cursor repair (#160) | core `client.rs`/`marmot.rs` | same core via FFI | PARITY | — | Shared |
| Direct-chat dedupe by peer (#164) | `SonarAppStore.swift:2780-2933` | `SonarAppState.kt` `dedupeDirectMarmotChats()` | PARITY | — | Same commit, both surfaces |
| Nonblocking secure chat startup (#159) | `SonarAppStore.swift` pending chats | `SonarAppState.kt:289-330` | PARITY | — | |
| Direct NIP-17 fallback for favorites | `SonarAppStore.swift:1655-2000` | `SonarAppState.kt:3879-4086` + `SonarOutbox` | PARITY | — | Slice 4 closed |
| NIP-17 persistence round-trip | iOS `MessageStore` | `SonarAppState.kt:4086` append; restart survival unverified | **PARTIAL** | M | Verify `MessageStore.saveChat()`→`loadChat()` covers NIP-17 payloads |
| Send queue + flush on reconnect | `SonarAppStore.swift:1655-1800` | `SonarAppState.kt:3879-3890` | PARITY | — | |
| Conversation folding (BLE/Sonar/WN) | `SonarAppStore.swift:409-2960` | `SonarAppState.kt:817-850` | PARITY | — | |
| Unread badges & read state | `SonarAppStore.swift:2618-2977` | `SonarAppState.kt:388-1975` | PARITY | — | |
| Folded-chat notification routing | `SonarAppStore.swift:2815` `maybeNotify()` checks folded set | Compose check against full `foldedGroupIds` unverified | **PARTIAL** | M | Risk: notification fires for open deduped chat after rekey |
| Core-rendered notifications (#144) | `sonarRenderNotification()` FFI | `SonarCore.android.kt:62-66` | PARITY | — | |
| Slash command registry | `CommandInfo.swift:13-58` | `SonarSlashCommands.kt` | PARITY | — | Same 9 commands + aliases |
| Slash command plaintext fallback in geo contexts | `CommandProcessor.swift:100-108` gates `/fav` etc. | Compose fall-through to text send unverified | **PARTIAL** | S | Slice 1 rule: never leak safety commands as plaintext |
| Chat open bounded local window | `MarmotChatView.swift:603-637` `loadLocalPage()` | Compose delegates to core `marmotMessagesPageForChat()` | **PARTIAL** | L | Verify core respects bounded page without relay wait (perf rule) |
| Local-first transcript hydration | `MarmotChatView.swift:249-258` snapshot cache | `SonarAppState.kt:244-330` snapshot init | PARITY | — | |
| Favorite/block persistence + mutual state | `FavoritesPersistenceService.swift` | `SonarAppState.kt:882-973` | PARITY | — | Slice 2 closed |
| Delete chat cascade over folded ids | `SonarAppStore.swift:5275-5291` | `SonarAppState.kt:2359-2396` | PARITY | — | |

## 2. Payments & wallet

| Feature | iOS (file:line) | Compose status | Classification | Size | Notes |
|---------|-----------------|----------------|-----------------|------|-------|
| Wallet setup & state machine | `WalletBridgeService.swift:176-256` | `WalletBridge.android.kt:50-82` | PARITY | — | |
| Seed derivation | `WalletBridgeService.swift:213-238` | `WalletSeed.kt:16-22` | PARITY | — | Documented deviation, both deterministic |
| Live balance observation | `WalletBridgeService.swift:562-571` stream | on-demand `refreshBalance()` only | **PARTIAL** | M | Compose balance stale until manual refresh |
| Create BOLT12 offer | `WalletBridgeService.swift:460-466` | `WalletBridge.android.kt:93-100` | PARITY | — | |
| Send to destination | `WalletBridgeService.swift:392-409` | `WalletBridge.android.kt:102-115` | PARITY | — | |
| FCM ↔ Breez NDS coordination | `SonarPushRegistration.swift:82-100` | `SonarPushRegistration.kt:81-102` | PARITY | — | |
| Webhook marker persistence | `SonarPushRegistration.swift:39-40` UserDefaults | `SonarPushRegistration.kt:29,47-50` `@Volatile` only | **PARTIAL** | S | Marker lost on process death → redundant webhook updates |
| Push wakeup classification (breez/transponder) | `SonarPushProcessor.swift:44-49` | `SonarPushProcessingService.kt:67-75` | PARITY | — | |
| Unify payer scan/connect/read | `UnifyNearbyService.swift` | `UnifyRadio.android.kt:97-241` | PARITY | — | |
| Unify receiver advertise/serve | iOS receiver service | `UnifyRadio.android.kt:245-325` | PARITY | — | iOS stops in background (BLE limitation) — PLATFORM-GAP, documented |
| Direct send flow (PaySheet → ⚡PAY) | `SonarPayViews.swift:29-78` | `SonarPayViews.kt:59-170` | PARITY | — | |
| Chat receipt ledger (⚡PAY/⚡PAYDONE) | `SonarPayLedger.swift:137-222` | `SonarPay.kt:73-120` | PARITY | — | |
| **Direct wallet payment activity ledger** | `SonarPayLedger.swift:295-366` `SonarPaymentActivityLedger` | `wallet/SonarPaymentActivity.kt` + `WalletBridge.paymentEvents` | PARITY | — | Closed in PR #168 batch 2; Compose renders a merged receipts+activity superset (documented deviation) |
| Wallet activity screen | `SonarWalletActivityScreen.swift:15-150` | `SonarWalletActivityScreen.kt` via `state.walletActivity()` | PARITY | — | Closed in PR #168 batch 2 |
| `hasLiveRate` signal | `WalletBridgeService.swift:143-145` | MISSING | **PARTIAL** | S | Compose can render blank fiat instead of sats fallback |
| Currency picker / fiat toggle | `WalletBridgeService.swift:486-505` | `WalletBridge.kt:52-56` | PARITY | — | |
| Breez API key wiring | `Configs/Local.xcconfig` | `local.properties` → BuildConfig | PARITY | — | Both gitignored |
| NDS host normalization | `SonarPushRegistration.swift:61` | `SonarPushRegistration.kt:40-43` | PARITY | — | |
| Offline-push hardening (closed PR #148) | on main via #147 | `SonarPushPrefs.kt` + killed-app wakeup (cherry-picked) | PARITY | — | Closed in PR #168 batch 2 (3 cherry-picks) |

## 3. Calls

| Feature | iOS (file:line) | Compose status | Classification | Size | Notes |
|---------|-----------------|----------------|-----------------|------|-------|
| DM header audio call button | `SonarDMScreen.swift:75` | `App.kt:737-738` | PARITY | — | |
| DM header video call button | `SonarDMScreen.swift:78` | `App.kt` DM header (gate removed) | PARITY | — | Closed in PR #168 batch 2; remote/local camera frames remain the shared core gap on BOTH platforms |
| Call screen states/controls (mute, speaker, end, pulse, E2E pill) | `SonarCallScreen.swift` | `CallScreen.kt` | PARITY | — | Verified control-by-control |
| Camera flip | `SonarCallScreen.swift:243-244` | `CallScreen.kt` + `ActiveCall.frontCamera` | PARITY | — | Closed in PR #168 batch 2 |
| `callStart`/`callPlace`/`callAccept`/`callHangup`/`callSetMuted`/`callWaitEvent` | `SonarAppStore.swift:4874-5053` | `SonarAppState.kt:417-566` | PARITY | — | |
| `callIncomingOffer()` before accept | `SonarAppStore.swift:5193` | MISSING — jumps to `callAccept()` | **GAP** | M | Skips iroh peer-address setup for incoming leg |
| Descriptor call gating on incoming offers | `SonarAppStore.swift:5153-5160` `canCall()` guard | MISSING | **GAP** | M | Compose accepts offers from peers without call capability |
| Stale offer rejection (>60s) | `SonarAppStore.swift:5166-5168` | MISSING | **GAP** | S | |
| Busy auto-decline (second incoming) | `SonarAppStore.swift:5170-5172` | MISSING | **GAP** | S | Race: user can accept 2nd call while connected |
| Deferred offer pending descriptor lookup | `SonarAppStore.swift:5154-5156` | MISSING | **GAP** | M | Offers can fail on slow descriptor fetch |
| Proximity sensor (voice calls) | `SonarAppStore.swift:4863,4979-4987` | `CallAudioRoute.android.kt` proximity wake lock | PARITY | — | Closed in PR #168 batch 2; released on speaker toggle like iOS |
| Audio session/route setup | `SonarAppStore.swift:5098-5107` | `CallAudioRoute.android.kt:14-30` | PARITY | — | |
| Immediate dismiss (Signal pattern) | decline/hangup pops instantly | same | PARITY | — | #104 |
| `canCall()` capability check (outgoing) | `SonarAppStore.swift:4461-4468` | `SonarAppState.kt` equivalent | PARITY | — | |
| CallKit / ConnectionService / full-screen intent | absent on BOTH | absent | PLATFORM-GAP | L | Neither surface has OS-level incoming-call UX; tracked follow-up, out of parity scope |

## 4. Media & UX polish

Slice-5 verification against current code:

| Feature | iOS | Compose | Classification | Size | Notes |
|---------|-----|---------|-----------------|------|-------|
| Radar peer tap → DM | single-action open | `SonarRadarScreen.kt:150` `openDm()` | PARITY | — | Closed by PR #140 (was toast) |
| Contact-profile favorite action | real toggle (`SonarAppStore.swift` social actions) | real toggle `SonarContactProfileScreen.kt:313-320` | PARITY | — | Closed in PR #168 batch 2 |
| Contact-profile block/delete | real, wired to `SecureIdentityStateManager` + `deleteChat` cascade | real `setContactBlocked()` `SonarContactProfileScreen.kt:322-329` | PARITY | — | Closed in PR #168 batch 2; iOS store-level block guards on `sendPay`/`placeCall` too |
| Blocked-contact unblock affordance | unblock row + gated actions | toast + unblock path `SonarContactProfileScreen.kt:172-174` | PARITY | — | Closed in PR #168 batch 2; open follow-up: iOS Marmot transcript re-filter on block (pre-existing) |
| Reactions / share-location rows | hidden | "coming soon" toasts `App.kt:562-563` | PARITY | — | Both defer; acceptable |
| Delivery status copy shared helper | `stateText()` | `SonarDeliveryText.kt` + tests | PARITY | — | Except partial-delivery label (§1) |
| **BLE mesh delivery receipts (`Sent` -> `Delivered`)** | `BLEService.handleFileTransfer` + `ChatViewModel.handleDelivered`; text and media | `MeshRadio.sendMeshDeliveryAck` / `drainMeshDeliveryReceipts`; text and media on Android, **text only** on Compose Desktop (`MeshRadio.jvm.kt` `sendMeshMedia` returns false) | PLATFORM-GAP | M | Encrypted `delivered` payload, so no new metadata on the wire. Text receipts are stock bitchat; the media `0x05` message-id TLV is a Sonar extension, so a stock peer returns no media receipt (unknown tags are skipped). Desktop gap tracked with the media row below. |
| **Receiver idempotence + duplicate re-ACK** | bounded sender-scoped `seenPrivateFileMessageIDs` in `BLEService` (needed because packet dedup keys on `senderID-timestamp-type`, which a retry does not collide with) | `drainMeshDms` / `drainMeshMedia` dedup on the sender-chosen wire id, gated on `!it.mine`, then re-ACK | PARITY | — | Prerequisite for any sender retry: without the re-ACK a lost receipt is unrecoverable, and without the dedup a retry duplicates the row. |
| **Sender-side no-receipt timeout** | MISSING | MISSING | **GAP** | M | A row whose receipt is lost stays `Sent` until the user re-sends. Needs gating on peers that have proven they ack — an ungated timeout would re-send at a stock bitchat peer forever (no media receipt) or wrongly mark a delivered message "Couldn't send". Receiver halves above are done, so this is unblocked. See `docs/REGRESSIONS.md` (Unguarded). |
| Media pipelines (image, voice, GIF, file), viewer, share/save | full | full on Android (`App.kt:1632-2072`, `MediaViewer`); Compose Desktop BLE send unsupported | PLATFORM-GAP | M | BLE 0x22 + MIP-04 on iOS/Android; native macOS shares Apple BLE media. Compose Desktop `sendMeshMedia` returns false; add desktop file framing/reassembly and receipt coverage. |
| Media caption field in model | `MarmotService.swift:121` `MarmotMedia.caption` | `SonarCore.kt` `SonarMedia.caption` + codec field 15 | PARITY | — | Closed in PR #168 batch 2 (model only, no UI yet — by design) |
| Multi-item media model | single picker | `List<SonarMedia>` | PARITY | — | Compose structurally ahead |
| Cleanup on exit paths | `onDisappear` chains | `cleanupPreviewTempFiles()` `App.kt:2333,2344` | PARITY | — | |
| Stickers send/receive/pack install | composer + views | `StickerBubble`/`StickerPackPreviewSheet` | PARITY | — | |
| **Reply-to-message (Signal quote chip)** | `SNReplyChrome` + `sendTextReply` NIP-C7 | `ReplyDecorated` + `SonarCore.sendReply` NIP-C7 | PARITY | — | Marmot kind-9 `q`+nevent; display body stripped in `to_chat_message`. Mesh TLV 0x04 skip-unknown is lockstep; BLE encode of `replyTo` and geohash `q` host wiring are follow-ups. Kill-switch `SONAR_REPLY_UI=0` hides chips/banner, strip stays. |
| Settings screens (appearance, wallet, notifications, export key, erase, wipe, about) | full | full | PARITY | — | Compose ahead on app-lock/app-icon/data-storage rows (iOS hides, no backend) |
| Profile nickname/QR/npub share | `SonarProfileScreen.swift:54-120` | `SonarProfileScreen.kt:75` (+ QR presence to verify) | PARITY | S | Spot-verify Compose QR share |
| Search/start affordances (invite links, shared text, npub, geohash) | app-level invite handling | search-sheet + queued handlers `App.kt:103-132` | PARTIAL | M | Flows differ; align or document |
| Onboarding restore / safety verify / radar RSSI / HereCard | full | full | PARITY | — | |

## 5. Recommended work packages (priority order)

**WP-A — Compose call-safety pack (messaging-critical, unit-testable):**
`callIncomingOffer()` wiring, `canCall()` incoming gate, stale-offer rejection,
busy auto-decline, deferred-offer-pending-descriptor. All in
`SonarAppState.kt`; mirrors `SonarAppStore.swift:5153-5193`.

**WP-B — Messaging small fixes:** partial-delivery label in
`SonarDeliveryText.kt`; slash-command plaintext fall-through guard; folded-set
notification check; NIP-17 persistence round-trip test (+fix if broken);
bounded-window verification of core `messages_page()`.

**WP-C — Payments:** `hasLiveRate` signal; webhook marker persistence
(SharedPreferences); live balance stream (Flow); direct wallet payment
activity ledger (L — own PR); cherry-pick offline-push-parity commits.

**WP-D — Calls hardware pack (device-gated):** enable video call UI + camera
flip + local preview (CameraX); proximity wake lock.

**WP-E — iOS UX pack:** contact-profile favorite + block/delete real actions,
blocked-state unblock affordance.

**WP-F — Model hygiene (both):** optional media caption field.

Hardware-gated verification checklist stays with each WP's PR description.
