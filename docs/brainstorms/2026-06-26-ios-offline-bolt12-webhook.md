# iOS offline BOLT12 receive — bind the webhook & win the NSE race (issue #126)

Date: 2026-06-26
Issue: https://github.com/hedwig-corp/bitchat-to-sonar/issues/126
Related: #125 (client FCM/NSE/App-Group work), #65 (NSE), #134 (background-SQLite fix, on main)

## Clarified Problem Statement

**Goal:** An offline (backgrounded *or* force-quit) iOS Sonar wallet reliably
receives a BOLT12 payment, by ensuring its receive offer carries the webhook and
the NSE settles within the payer's `bolt12/fetch` timeout.

**Scope decisions (from brainstorm):**
- Keep the current BOLT12-offer + self-hosted NDS + FCM + NSE architecture. No
  LNURL pivot in this change.
- Must work after **force-quit/killed**, not just backgrounded.

**Constraints:**
- Don't regress online→online pay (works today) or the Transponder chat/call
  APNs path (raw-token, separate channel).
- Don't break Android, which already works on the same NDS — this is an
  iOS-only gap.
- No payment/wallet secrets committed (Local Secrets Rule); seed handling stays
  local. Moving the seed to a shared Keychain access group must keep it
  device-local.
- All benchmark/instrumentation hooks `#if DEBUG` only (Performance Analysis
  Rule).

**Non-goals (this change):**
- LNURL / Lightning-address receive pivot (tracked follow-up — the official
  misty-breez reference leans LNURL precisely because it tolerates a slow wake).
- Hosted hold-invoice / LSP async receive.
- VoIP/PushKit (reserved for the future call feature; ruled out below).

**Success criteria:**
- A **real `POST /api/v1/notify`** lands on `sonar-breez-nds` for a Sonar offer
  (today: zero).
- iPhone SDK logs show an `update_bolt12_offer` PATCH writing the webhook onto
  our offer.
- End-to-end: paying an offer to a **force-quit** device settles before the
  payer's `bolt12/fetch` `TimedOut`.

## Root cause (confirmed in #126)

Breez `breez-sdk-liquid` (0.11.13) snapshots `get_webhook_url()` **at
`create_bolt12_offer` time** and POSTs the offer to Boltz with `url=`. Our
receive offer predates the webhook feature, so it sits on Boltz with
`url=None`. `registerWebhook()` only re-PATCHes offers already present in the
SDK's local `bolt12_offers` table (`list_bolt12_offers` → `update_bolt12_offer`)
and **silently no-ops on an empty list**. So Boltz has nothing to call → no FCM
push → the NSE never wakes.

## iOS "special application" research (VoIP / PushKit and the force-quit wall)

The strategic question: is there a privileged wake primitive (like VoIP push)
Sonar could use to reliably resurrect a killed app for a payment? **No — and the
issue's instinct is correct.**

1. **VoIP / PushKit is a dead end for payments.** Since iOS 13 a PushKit VoIP
   push **must report an incoming call to CallKit in the same run loop** as
   `didReceiveIncomingPush`, synchronously, or iOS terminates the app
   (`"Killing app because it never posted an incoming call ..."`). Repeated
   violations make iOS stop delivering VoIP pushes to the app. It cannot be
   repurposed to silently settle a payment. Reserved for the future call
   feature.
   - https://developer.apple.com/forums/thread/117939
   - https://github.com/twilio/voice-quickstart-ios/issues/251
2. **No "financial background" entitlement equivalent of VoIP.** Apple Pay /
   PassKit / `payment-pass-provisioning` / FinanceKit grant data access and
   provisioning, not background execution.
   - https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/ApplePayandPassKitEntitlements/ApplePayandPassKitEntitlements.html
   - https://developer.apple.com/financekit/
3. **Silent push (`content-available`) is unusable after force-quit** — iOS
   blocks background launch and throttles silent pushes once the user swipes the
   app away.
4. **BackgroundTasks (BGProcessingTask/BGAppRefreshTask) are opportunistic** —
   scheduled minutes-to-hours later; useless in a ~36s window.
5. **The only force-quit-capable mechanism is what Sonar already uses:** a
   visible `mutable-content` push → Notification Service Extension (the WhatsApp
   mechanism), ~30s budget.

**Conclusion:** the architecture is already on the only viable force-quit rail.
The problem reduces to (a) bind the webhook to our offer so the push fires, and
(b) win the ~30s NSE budget vs the payer's ~36s `bolt12/fetch` timeout.

## Approaches Considered

### Approach A: Diagnose & fix the local `bolt12_offers` DB so `registerWebhook` PATCH lands
- **Sketch:** The no-op-on-empty-list behavior suggests our offer row isn't in
  the `bolt12_offers` table the app/NSE sees — plausibly because #125 moved the
  Breez working dir into the App Group and the old row didn't migrate. Make the
  working-dir/DB path identical between app and NSE, confirm the row exists, then
  run `unregister → register` to force the PATCH onto the existing offer.
- **Affected:** `ios/localPackages/SonarWalletKit/Sources/SonarWallet.swift`
  (working dir + `mirrorBreezCredsToAppGroup`),
  `ios/SonarNotificationService/NotificationService.swift:27` (`getConnectRequest`
  working dir), `ios/bitchat/Services/SonarPushRegistration.swift:155`
  (`subscribeBreezWebhook`), `ios/bitchat/Services/WalletBridgeService.swift`.
- **Tradeoffs:** Smallest fix; **preserves the existing offer** (no rotation) if
  the row is recoverable. Needs a device-log capture to confirm. If the row is
  genuinely gone, this alone won't bind the webhook.
- **Effort:** S–M

### Approach B: Re-mint the offer with the webhook bound (offer rotation + migration)
- **Sketch:** Set the webhook URL, then force a fresh `create_bolt12_offer` so
  the new offer snapshots `url=`. Migrate the wallet's published receive offer to
  the new one everywhere it's surfaced (QR, share sheet, kind-0/profile, npub
  link); keep honoring the old offer where possible.
- **Affected:** wallet offer-creation wrapper (Rust core +
  `ios/bitchat/Services/WalletBridgeService.swift`), every offer-publish site
  (profile/QR/share), `ios/bitchat/Services/SonarPushRegistration.swift:155`.
- **Tradeoffs:** **Definitively fixes the binding** regardless of DB state — the
  guaranteed-correct path. Costs an offer rotation (holders of the old offer
  string must refresh). Needs a migration story and likely Android offer-lifecycle
  alignment (one identity per person).
- **Effort:** M

### Approach C: Win the NSE race for force-quit (speed + payer retry)
- **Sketch:** Binding is necessary but not sufficient — the one observed success
  took ~46s > the ~36s payer window. Minimize NSE cold-launch→settle: keep Breez
  SQLite readable in the background (now on main via #134 / `e4a8e77c`), move the
  seed from App Group `UserDefaults` to a shared Keychain access group
  (misty-breez pattern), keep `syncServiceUrl=nil`, and push for payer auto-retry /
  a longer `bolt12/fetch` window.
- **Affected:** `ios/SonarNotificationService/NotificationService.swift`,
  entitlements (keychain access group) in
  `ios/SonarNotificationService/SonarNotificationService.entitlements` +
  `ios/bitchat/bitchat.entitlements`,
  `ios/localPackages/SonarWalletKit/Sources/SonarWallet.swift`.
- **Tradeoffs:** **Required for force-quit no matter what.** Partly outside our
  control (payer's wallet/SDK governs retry/timeout). The background-SQLite angle
  is delicate — use the #134 variant on main, do not re-introduce the reverted
  crash.
- **Effort:** M

## Recommendation — sequence A → (B if needed) → C in parallel

1. **A first** — cheapest, non-destructive, and the most likely true root cause:
   the #125 working-dir move lines up exactly with "PATCH no-ops because the
   offer isn't in the local list." Confirm with one device-log capture.
2. **B as the guaranteed fallback** — if the offer row is unrecoverable, re-mint
   with the webhook bound; accept the offer-rotation cost.
3. **C from the start** — force-quit requires settlement to beat ~36s. Levers:
   the #134 background-SQLite fix (already on main) and the App-Group→Keychain
   creds move; the payer-retry ask goes to whoever owns the counterparty/swap
   side.

Also **document LNURL as the tracked robustness follow-up** — not built now, but
keep the seam open if C can't reliably win the race.

## Open questions
- Is the `bolt12_offers` row actually present in the App-Group DB post-#125?
  (Blocks A vs B — needs the `idevicesyslog`/USB capture #126 flags.)
- Can the payer side retry or extend the `bolt12/fetch` window? If not, C's
  ceiling is hard and LNURL gets more urgent.
- Does re-minting (B) require a coordinated Android offer-lifecycle change to
  keep one identity per person?
- Firebase APNs key Team ID mismatch (`L3N5LHJD5Y` vs `ZQB239SHCM`) — cosmetic
  until the server POSTs, but bites the moment A/B succeed.

## Implementation order (for /ship)
1. **A — DB/working-dir consistency + verify PATCH.** Make app and NSE use the
   identical Breez working dir; add a DEBUG-gated log of `list_bolt12_offers`
   count before `registerWebhook`; do `unregister → register` to force the PATCH.
2. **C — creds + NSE speed.** Move seed to a shared Keychain access group; keep
   `syncServiceUrl=nil`; confirm the #134 background-SQLite fix is in the NSE
   connect path; measure connect→answer time.
3. **B — only if A proves the offer row is gone.** Re-mint the offer with the
   webhook bound and migrate every publish site; align Android.
4. **Verify:** a real `POST /api/v1/notify` on `sonar-breez-nds`; `update_bolt12_offer`
   PATCH in SDK logs; end-to-end force-quit settle within the payer window.
5. **Follow-up (tracked, not in this change):** LNURL / Lightning-address path
   as the slow-wake-tolerant alternative.
