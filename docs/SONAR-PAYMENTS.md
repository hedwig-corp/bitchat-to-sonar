# Sonar Payments

Status: v2 draft (June 2026). UI: `bitchat/Views/Sonar/SonarPayViews.swift`,
protocol/state: `bitchat/Views/Sonar/SonarPayLedger.swift`, wallet
abstraction: `bitchat/Views/Sonar/SonarWalletStore.swift`. Design source of
truth: `design/handoff/project/sonar/pay.jsx` + the `.pay-*` styles in
`theme.css` (gold tokens).

## Current send path: direct wallet payment

New Sonar clients do not create claimable chat coins when sending money. The
receiver publishes public payment metadata in their NIP-78-style Sonar
descriptor, and the sender pays that wallet destination directly.

The app publishes two addressable kind `30078` descriptor events during
migration:

- `d=sonar.call.v1`: old call-only schema for old clients.
- `d=sonar.meta.v1`: unified Sonar metadata. This is the preferred schema and
  carries direct payment receive metadata.

The payment part of `sonar.meta.v1` is:

```json
{
  "schema": 2,
  "app": "sonar",
  "payments": {
    "receive": [
      {
        "type": "bolt12_offer",
        "offer": "lno1...",
        "network": "bitcoin",
        "proofs": ["preimage"],
        "future_proofs": ["bolt12_payer_proof"]
      }
    ],
    "receipts": ["sonar.payment.receipt.v1"]
  }
}
```

Send flow:

```text
sender                                      receiver
------                                      --------
fetch sonar.meta.v1
read payments.receive[bolt12_offer]
record activity: pending
wallet.send(offer, sats) → preimage
record activity: paid/failed
⚡PAY|1|<uuid>|<sats> --------------------> record incoming receipt: pending
⚡PAYDONE|2|<uuid>|<preimage> ------------> mark receipt paid + store preimage
```

The current proof is the Lightning preimage. When
`lightning/bolts#1295` lands, Sonar can add payer proofs without changing the
descriptor shape because `future_proofs` already advertises that direction.

Direct sends require a valid BOLT12 offer from the peer's Sonar metadata. BLE
payment capability bits may show the affordance while the descriptor is being
fetched, but sending refuses until the concrete offer is available.

### Descriptor cache durability (why "Send bitcoin" must not flicker)

A resolved descriptor is the *only* payment route for a pure White Noise
contact — a peer met over BLE also carries the `CAP_PAY` bit in their persisted
profile, but an npub-only contact does not. Two invariants follow, and both
have already caused an intermittent "the bitcoin payment option is not showing"
report:

1. **A relay miss must never evict a resolved descriptor.** `fetch_sonar_descriptor`
   returns `Ok(None)` for an ordinary empty result — relays reconnecting after
   background, the 10 s `FETCH_TIMEOUT` expiring, a relay that simply does not
   hold the event. Treating that as "this peer has no offer" drops a known-good
   BOLT12 offer and silently removes the payment row from a chat that was
   payable a moment ago. Keep the last resolved descriptor and stamp only the
   miss, so the short miss cooldown (not the long success TTL) drives the retry.
   Compose: `SonarAppState.performDescriptorFetch`. iOS:
   `MarmotChatModel.performDescriptorFetch` /
   `MarmotChatModel.descriptorCacheAfterFetch`.
2. **The cache is durable, not per-process.** Holding descriptors only in memory
   hides the payment affordance on every cold start until a relay round-trip
   lands. Persist them and hydrate at init so payments paint from local state
   first (Signal-Comparable Performance Rule). Compose:
   `SONAR_DESCRIPTOR_CACHE_BLOB_KEY`. iOS: `SNMarmotDescriptorCache`. Both cap
   the set at 1024 and evict by **local fetch recency**, pinning the key just
   fetched. Evicting by the peer's `published_at` looks equivalent and is not:
   a contact who published their descriptor long ago would be dropped the
   instant we cached them, so the fetch achieves nothing, they stay unpayable,
   and every chat open refetches the same event. Published-at survives only as
   the tiebreak that orders entries hydrated from disk, which have no local
   fetch time yet.
   The per-fetch write does its encode **off** the UI thread (Compose
   `scheduleContactCacheWrite`, iOS `scheduleDescriptorCacheWrite`) — a
   relay-startup sweep resolves N contacts, and encoding the whole map N times
   on the render path is a Signal-Comparable Performance Rule violation. Only
   wipe/teardown writes synchronously, because it must observe the blob cleared
   before the account is replaced; it also invalidates any deferred write still
   in flight so an erased contact cannot be resurrected.
3. **Clear on identity death, not on "erase all chats".** Descriptors belong to
   the *account*, so only a panic wipe or an identity replacement may drop them
   (iOS `clearAccountContactDescriptors`, called from `wipeDatabase` and
   `prepareForIdentityReplacement` — deliberately NOT from
   `eraseChatsKeepIdentity`; Compose clears in `wipe()` / `restoreAccount()`,
   deliberately NOT in `eraseAllChats()`). Erasing chats keeps the identity, so
   wiping the cache there would strip the payment affordance from every pure
   White Noise contact until a relay fetch succeeds — re-creating invariant 1's
   bug through a different door. A fetch started under the previous identity is
   dropped by a generation guard, captured at schedule time rather than at fetch
   start, so a wipe landing mid-flight cannot persist the old account's contacts
   into the new one.

## Entry points

There are two ways to start a payment:

1. **From inside a chat** — the "+" composer action. Pays that conversation's
   peer and posts the ⚡PAY receipt bubbles into the transcript.
2. **From the new-chat sheet** — *Start a chat → Send a payment*, which opens
   the standalone send-payment picker
   (`SonarSendPaymentScreen.kt` / `SonarSendPaymentScreen.swift`, reproducing
   the design's `SendPaymentScreen` in
   `design/handoff/project/sonar/pay.jsx`). It offers two recipient kinds:
   - **A contact** from "People you can pay" — every conversation whose peer
     already published a BOLT12 offer. The payment is routed through
     `sendPay(chatId)`, so it is identical to paying from inside the chat and
     the peer still gets the in-chat receipt. The list is built **cache-only**:
     it never fetches a descriptor, so opening the picker cannot block on the
     relay. A contact whose descriptor has not arrived yet is simply not
     listed.
   - **Anyone else** — a BOLT12 offer (`lno1…`), a BOLT11 invoice
     (`lnbc…`/`lntb…`), or a Lightning address (`name@domain`) typed into the
     field. The wallet resolves the destination
     (`payDestination` / `payDestinationDetached`). There is no conversation to
     post a receipt into, so only the wallet activity row is written, with
     `peerKey = "wallet"`.

   An `npub` is deliberately **not** an external destination: it is a Sonar
   identity, not something the wallet can pay. Such a person shows up under
   "People you can pay" once their descriptor arrives.

   - **A scanned QR code** — "Scan a QR code" opens the design's `ScanQrSheet`
     viewfinder. iOS reuses the `AVCaptureMetadataOutput` pipeline that already
     powers safety-number verification (`CameraScannerView`); Android uses
     CameraX + zxing (`SonarQrScanner`), decoding the Y plane on a background
     executor with `STRATEGY_KEEP_ONLY_LATEST` so a slow frame is dropped
     rather than queued. The decoded payload is classified the same way as a
     typed one, and a BOLT11 invoice that encodes an amount carries it through
     as the sheet's fixed amount — the keypad and quick chips are then hidden,
     matching the design's `fixed` prop.

**Platform gap:** desktop has no camera pipeline (CameraX is Android-only and
there is no cross-platform JVM webcam stack Sonar ships), so
`sonarQrScanSupported()` is false on the JVM target and the scan row is hidden
there rather than opening a dead viewfinder. Pasting a code into the field
reaches every destination the scanner would.

## Chat UX

Money still appears inside the chat. A direct send pays the receiver's wallet,
then posts gold payment receipt bubbles using the encrypted chat transport.
There is no "tap to claim" step for these bubbles.

The **Wallet → Activity** screen is a log only, reproducing the design's
`WalletScreen` + `WalletActivity`: the centered balance block, then the
transaction list — no Send/Receive buttons, because paying always starts from
the new-chat sheet or from inside a chat. Each row is
`send`/`download` glyph on indigo/green · "To <who>" / "From <who>" ·
"<status> · <rail> · <time>" · a signed amount that greys out and strikes
through when the payment failed.

One data gap feeds that row: Compose's `PayEntry` does not persist a peer key,
so a chat ⚡PAY receipt with no matching wallet-activity row has no name to
show and falls back to the design's own "unknown". Direct wallet activity
always carries `peerName`. iOS renders from the activity ledger only, so it is
unaffected.

The wallet sheet also lists direct payment activity, newest first, including:

- Sonar direct sends to Nostr/Sonar peers.
- Unify nearby sends to Bluetooth-discovered Unify wallets.
- Generic incoming wallet payments when the wallet backend reports settlement
  events. These may not yet be attributable to a Sonar peer.
- Status, amount, peer name, rail, wallet payment id, fee, and failure text
  when available.

## Chat receipt wire format

```text
⚡PAY|1|<uuid>|<sats>                payment receipt (sender -> receiver)
⚡PAYDONE|2|<uuid>                   settled receipt, no preimage available
⚡PAYDONE|2|<uuid>|<preimage_hex>    settled receipt with cryptographic proof
```

`<preimage_hex>` is the 32-byte Lightning preimage (64 hex chars). Receivers
can verify settlement by checking `SHA256(preimage) == payment_hash`.

`⚡PAY` is a receipt, not a Bitcoin claim primitive. `⚡PAYDONE` can race ahead of
`⚡PAY` on relay-backed transports; clients remember that DONE and mark the
matching incoming receipt paid once the `⚡PAY` line arrives. Unknown versions
render as plain text. `⚡PAYCLAIM` is not part of the protocol.

Backward compatibility: decoders accept `⚡PAYDONE|1|<uuid>` from old peers
(no preimage, receipt still transitions to paid). New clients always emit v2.

Control-line processing is idempotent, so replaying transcripts after relaunch
is safe.

## Local state

`SonarPayLedger` stores chat receipt rows in UserDefaults JSON under
`sonar.pay.ledger.v1`: `{id, peerKey, sats, direction, state, via, preimage?}`.

`SonarPaymentActivityLedger` stores direct wallet payment activity under
`sonar.payment.activity.v1`. Entries are not claimable state machines; they are
local audit rows for app-initiated sends and wallet-reported receives:

```text
id, kind, peerKey, peerName, direction, sats, via, createdAt,
destinationHash, status, walletPaymentId, feesSats, settledAt, failure
```

Erase-all-chats clears both local ledgers because their rows render inside
conversations. Emergency wipe also clears them and destroys the wallet seed.

## Missing offer behavior

When a peer has no direct receive offer:

- Calls can still use `sonar.call.v1`.
- New "Send money" is hidden because there is no direct receive offer to pay.

This avoids presenting a claimable UX for a payment that now settles directly.

## External payment status (paystatus.jsx Direction D)

A payment to a *contact* reports into their chat as a `⚡PAY` receipt. A payment
to an **external destination** — a scanned QR, a pasted BOLT12 offer or BOLT11
invoice, a `name@domain` Lightning address — has no conversation to report into,
so it gets its own screen: `Send payment → Pay → Payment`.

The design (`design/handoff/project/Sonar Payment Status.html` +
`sonar/paystatus.jsx`) explored four directions; **D · resumable status**
shipped, because the persisted `SonarPaymentActivityLedger` already owns the
outcome and keeps updating after the screen is gone — the promise D makes is the
only one the architecture can honestly keep.

The brief every state must answer: *what is happening*, **where is my money**,
and *what do I do next*. The copy tables that answer it live in exactly two
places and must stay in step:

- `ios/bitchat/Views/Sonar/SonarPaymentStatus.swift` (`SNPayStatusCopy`)
- `apps/sonar/.../wallet/PaymentStatus.kt` (`PayStatusCopy`)

Both are pinned by `SonarPaymentStatusTests` / `PaymentStatusTest`.

### Phases and how each is derived

| Phase | Source | Reachable today |
| --- | --- | --- |
| `resolving` | live send, wallet not yet called | yes (brief) |
| `paying` | live send, wallet called | yes |
| `slow` | live send, in flight ≥ 20s | yes |
| `sent` | ledger row `paid` | yes |
| `failedSafe` | ledger row `failed` | yes |
| `refunded` | — | **no** (see below) |
| `unknown` | ledger row `pending`, no live send | yes (killed mid-send) |

The ledger is the source of truth; the in-memory live entry only refines a row
that is still `pending`. That ordering is what stops the screen from showing
"sending" over a payment that already settled.

`refunded` is rendered but unreachable: the wallet's `send` either returns a
settled payment or throws, so we cannot today distinguish "money left and came
back" from "never left". Reaching it needs a wallet-side refund event —
tracked follow-up, not a UI change.

### Deliberate deviations from the design

- **Cancel is dropped once the payment reaches the wallet.** The design offers
  `Cancel` on `resolving` and `Cancel payment` on `slow`. An in-flight Lightning
  payment cannot be recalled, and a button that claims otherwise is the exact
  dishonesty this screen exists to remove. `resolving` keeps its `Cancel`
  because it is genuinely before the hand-off.
- **`Try again` only within the session.** The ledger stores a SHA-256 of the
  destination, never the destination itself, and that stays true. The plaintext
  needed to re-send is memory-only, so after a relaunch the action is replaced
  by `Done` rather than offering a retry that cannot run.

### Home surface

H1 (pinned strip) shipped, shown **only while a payment is live** and cleared on
settle or failure — an in-flight payment must be impossible to miss, but a
settled one belongs in wallet Activity, not pinned over the chat list. A
`pending` row left by a killed process is deliberately excluded from the strip:
it can never resolve itself, and a banner that never goes away is worse than
none. Tapping the strip opens the status screen.

### Known cross-platform gap

Amount grouping differs: iOS `sonarGroupedSats` follows the device locale
(`2.100` on it-IT), Compose `payFmt` hard-codes en-US commas (`2,100`). This
predates the status screen and affects every money surface in both apps; the
status tests assert wording, not the separator. Unifying it is a follow-up.
