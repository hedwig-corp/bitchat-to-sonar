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
wallet.send(offer, sats)
record activity: paid/failed
⚡PAY|1|<uuid>|<sats> --------------------> record incoming receipt: pending
⚡PAYDONE|1|<uuid> -----------------------> mark receipt paid
```

The current proof is the Lightning preimage. When
`lightning/bolts#1295` lands, Sonar can add payer proofs without changing the
descriptor shape because `future_proofs` already advertises that direction.

Direct sends require a valid BOLT12 offer from the peer's Sonar metadata. BLE
payment capability bits may show the affordance while the descriptor is being
fetched, but sending refuses until the concrete offer is available.

## Chat UX

Money still appears inside the chat. A direct send pays the receiver's wallet,
then posts gold payment receipt bubbles using the encrypted chat transport.
There is no "tap to claim" step for these bubbles.

The wallet sheet also lists direct payment activity, newest first, including:

- Sonar direct sends to Nostr/Sonar peers.
- Unify nearby sends to Bluetooth-discovered Unify wallets.
- Generic incoming wallet payments when the wallet backend reports settlement
  events. These may not yet be attributable to a Sonar peer.
- Status, amount, peer name, rail, wallet payment id, fee, and failure text
  when available.

## Chat receipt wire format

```text
⚡PAY|1|<uuid>|<sats>   payment receipt (sender -> receiver)
⚡PAYDONE|1|<uuid>      settled receipt (sender -> receiver)
```

`⚡PAY` is a receipt, not a Bitcoin claim primitive. `⚡PAYDONE` can race ahead of
`⚡PAY` on relay-backed transports; clients remember that DONE and mark the
matching incoming receipt paid once the `⚡PAY` line arrives. Unknown versions
render as plain text. `⚡PAYCLAIM` is not part of the protocol.

Control-line processing is idempotent, so replaying transcripts after relaunch
is safe.

## Local state

`SonarPayLedger` stores chat receipt rows in UserDefaults JSON under
`sonar.pay.ledger.v1`: `{id, peerKey, sats, direction, state, via}`.

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
