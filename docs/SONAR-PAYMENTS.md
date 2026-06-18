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
                                             later: payment receipt event
                                             proves settlement with preimage
```

The current proof is the Lightning preimage. When
`lightning/bolts#1295` lands, Sonar can add payer proofs without changing the
descriptor shape because `future_proofs` already advertises that direction.

Direct sends only unlock when a valid BOLT12 offer is present in
`sonar.meta.v1`. Old BLE payment capability bits and old call-only descriptors
do not unlock new sending.

## Chat UX

Money still appears inside the chat. A direct send creates a local gold payment
bubble immediately, with state lines for sending, paid, or failed. There is no
"tap to claim" step for these bubbles.

The wallet sheet also lists direct payment activity, newest first, including:

- Sonar direct sends to Nostr/Sonar peers.
- Unify nearby sends to Bluetooth-discovered Unify wallets.
- Generic incoming wallet payments when the wallet backend reports settlement
  events. These may not yet be attributable to a Sonar peer.
- Status, amount, peer name, rail, wallet payment id, fee, and failure text
  when available.

## Legacy compatibility: claimable `⚡PAY`

Old Sonar clients may still send claimable chat payments. New clients keep the
old receive path so those messages do not break.

Legacy wire format:

```text
⚡PAY|1|<uuid>|<sats>              sealed coin (sender -> receiver)
⚡PAYCLAIM|1|<uuid>|<bolt12offer>  claim (receiver -> sender)
⚡PAYDONE|1|<uuid>                 settled (sender -> receiver)
```

Legacy settlement:

```text
sender                                   receiver
------                                   --------
ledger: outgoing sealed
⚡PAY ----------------------------------> ledger: incoming sealed
                                          wallet.createOffer()
ledger: sealed -> settling <------------ ⚡PAYCLAIM
wallet.send(offer, sats)
ledger: settling -> claimed
⚡PAYDONE ------------------------------> ledger: claiming -> claimed
```

Unknown legacy versions render as plain text. Control-line processing is
idempotent, so replaying old transcripts after relaunch is safe.

## Local state

`SonarPayLedger` stores legacy claimable coins in UserDefaults JSON under
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

## Old schema behavior

When a peer has only the old schema:

- Calls can still use `sonar.call.v1`.
- Incoming legacy `⚡PAY` can still be claimed.
- New "Send money" is hidden because there is no direct receive offer to pay.

This avoids presenting a claimable UX for a payment that can now settle
directly, while keeping old peers readable during migration.
