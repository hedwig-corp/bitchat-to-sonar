# Direct BOLT12 payments for Sonar contacts

Date: 2026-06-17
Status: clarified brainstorm output, no code changes.

## Context findings

- Current Sonar payments are documented as claimable sealed coins in
  `docs/SONAR-PAYMENTS.md`: `PAY -> PAYCLAIM -> PAYDONE`. That model is now the
  wrong UX for BOLT12 offers because nothing should wait for the receiver to
  claim inside chat.
- Current Sonar public metadata uses NIP-78 kind `30078` with
  `d=sonar.call.v1`, implemented in `core/sonar-core/src/sonar_descriptor.rs`.
  The descriptor only carries call metadata today.
- NIP-78 is appropriate for Sonar-specific app metadata: it defines addressable
  custom app data events with kind `30078` and arbitrary content/tags.
- NIP-57 zap receipts are useful prior art for receipt shape, but they are
  LNURL/BOLT11-oriented and explicitly not strong payment proof. They do not
  cleanly model direct BOLT12 offer payments.
- BOLT12 payer proofs are not available yet. The upstream payer-proof proposal
  is still open: `lightning/bolts#1295`.
- NIP-47 BOLT12 support is also still open as `nostr-protocol/nips#1952`, so
  Sonar should not depend on it for the first direct-payment version.

References:

- https://nips.nostr.com/78
- https://nips.nostr.com/57
- https://github.com/lightning/bolts/pull/1295
- https://github.com/nostr-protocol/nips/pull/1952

## Clarified Problem Statement

**Goal:** Replace claimable in-chat payments with direct BOLT12 payments: the
receiver publishes payment metadata, the sender pays immediately with an amount,
and both sides track the resulting wallet transaction and optional receipt.

**Constraints:**

- Payment capability must be explicit in fetched metadata. Missing or old
  metadata means "no direct payment support".
- The sender must validate that the payment metadata event is authored by the
  receiver's npub.
- The reusable BOLT12 offer is not mutated. The amount is supplied through the
  wallet payment request / invoice-fetch path.
- The wallet transaction ledger is the source of truth for settled money.
- Receipts are signed Sonar/Nostr statements, not cryptographic proof until
  payer proofs are standardized and exposed by wallets.
- Old clients must keep call discovery working during migration.

**Non-goals:**

- Keeping the claimable sealed-coin UX as the primary payment path.
- Treating NIP-57 zap receipts as the Sonar direct-payment protocol.
- Requiring NIP-47 BOLT12 support for the first version.
- Perfect attribution of every incoming wallet transaction to a Sonar sender in
  v1. Showing all wallet transactions is acceptable first.

**Success criteria:**

- A new client fetches a peer's Sonar metadata and sees a BOLT12 receive offer.
- A sender can choose an amount, pay the receiver's BOLT12 offer, and see the
  outgoing wallet transaction in local payment activity.
- A receiver can see wallet transaction history, including incoming payments
  even when attribution is unknown.
- If the receiver publishes a Sonar payment update, the sender and receiver can
  attach it to the payment activity.
- Old-schema peers do not show a broken direct-payment button.

## Proposed Protocol

### Metadata event

Publish a new NIP-78 descriptor:

- kind: `30078`
- `d` tag: `sonar.meta.v1`
- author: receiver npub
- content: JSON with calls, transports, and payments.

Example content:

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
  },
  "calls": true,
  "signaling": ["marmot"],
  "transports": ["iroh"]
}
```

Keep publishing the old `d=sonar.call.v1` descriptor during migration so old
clients continue to discover calls.

### Send flow

1. A opens a payment to B.
2. A fetches `kind=30078`, `author=B`, `#d=sonar.meta.v1`.
3. A verifies the event author and schema.
4. A extracts the preferred `bolt12_offer`.
5. A creates local outgoing activity: `pending`.
6. A asks the wallet to pay the offer with the selected amount.
7. On success, A stores the wallet payment id, amount, fees, timestamp, and
   status `paid`.
8. On failure, A stores status `failed` with a short error.

### Receiver flow

1. B's wallet observes or lists incoming transactions.
2. B shows all wallet transactions in a wallet activity view.
3. If the transaction carries enough metadata to correlate it to Sonar, B links
   it to the sender/payment activity.
4. B can publish or send a Sonar payment update after settlement.

### Payment update

Use a Sonar-specific receipt/update event, not NIP-57 as-is. Two possible
placements:

- Public Nostr event if the payment is intentionally public.
- Encrypted Marmot/DM message if payment activity should stay private between A
  and B.

Suggested v1 receipt fields:

```json
{
  "schema": 1,
  "app": "sonar",
  "type": "payment_receipt",
  "payment_id": "client-generated-correlation-id",
  "payer": "npub1...",
  "receiver": "npub1...",
  "amount_msat": "21000000",
  "offer_hash": "sha256...",
  "wallet_payment_id": "optional",
  "preimage": "optional",
  "proof_type": "preimage_trusted",
  "created_at": 1781690000
}
```

When BOLT12 payer proofs land and wallets expose them, add:

```json
{
  "proof_type": "bolt12_payer_proof",
  "payer_proof": "..."
}
```

## Old Schema Compatibility

### Migration rule

Publish both descriptors:

- old: `kind=30078`, `d=sonar.call.v1`
- new: `kind=30078`, `d=sonar.meta.v1`

New clients fetch `sonar.meta.v1` first. If missing, they can still fetch
`sonar.call.v1` for calls, but they must not infer direct-payment capability.

### Compatibility matrix

| Sender | Receiver | Behavior |
| --- | --- | --- |
| New | New | Direct BOLT12 payment plus local activity and optional receipt |
| New | Old schema only | Text/calls can work; direct payment hidden or disabled |
| Old | New | New receiver may support legacy `PAY` lines temporarily or show unsupported |
| Old | Old | Existing claimable flow continues |

### Legacy `PAY` handling

For a short migration window, new clients may decode incoming legacy
`PAY|1`/`PAYCLAIM|1`/`PAYDONE|1` lines to avoid losing UX for old senders. New
clients should not initiate legacy claimable payments by default. If legacy
lines are unsupported, render a clear local system message such as "Legacy
payment request unsupported. Ask the sender to update."

## Approaches Considered

### Approach A: Extend the existing call descriptor

- Sketch: add `payments` fields to the existing `d=sonar.call.v1` content and
  bump the schema.
- Affected files: `core/sonar-core/src/sonar_descriptor.rs`,
  `core/sonar-ffi/src/lib.rs`, `ios/bitchat/Services/MarmotService.swift`,
  app-layer payment gating.
- Tradeoffs: fewer Nostr events. But the `d` tag name is wrong, old parsers may
  reject new schema content, and call-only fallback becomes messy.
- Effort: M.

### Approach B: New unified Sonar metadata descriptor

- Sketch: introduce `d=sonar.meta.v1` for all account-level Sonar metadata,
  while keeping `sonar.call.v1` during migration.
- Affected files: descriptor codec/fetch/publish in Rust and FFI, Apple and
  Compose descriptor caches, docs, payment gating, wallet activity.
- Tradeoffs: clean schema boundary and safe migration. Requires one more
  descriptor fetch/publish path.
- Effort: M/L.

### Approach C: Use existing Nostr zap conventions

- Sketch: model Sonar payments as NIP-57-like zap requests and zap receipts.
- Affected files: payment protocol docs, Nostr event handling, wallet integration.
- Tradeoffs: more interoperable with Nostr social clients, but the flow is
  LNURL/BOLT11-shaped and does not cleanly fit direct BOLT12 reusable offers.
- Effort: L.

## Recommendation

Use Approach B: add `sonar.meta.v1` and migrate safely. It gives direct BOLT12
payments an explicit capability surface, preserves old call discovery, and keeps
payment UX honest: direct sends are paid by the wallet, not claimed from chat.

Implement in phases:

1. Document and ship `sonar.meta.v1` with payment receive metadata.
2. Add direct-payment gating: show "Send money" only when metadata contains a
   supported receive method.
3. Replace outgoing claimable sends with direct wallet sends.
4. Add wallet transaction history and local payment activity.
5. Add Sonar payment updates/receipts.
6. Keep legacy `PAY` receive support temporarily, then remove once old clients
   are no longer relevant.

## Open Questions

- Should Sonar payment updates be public Nostr events, encrypted Marmot messages,
  or both depending on user intent?
- Should the reusable BOLT12 offer be public in `sonar.meta.v1`, or should the
  public descriptor contain only a payment capability and an encrypted fetch path?
- What correlation data can Breez expose for incoming payments today: payer note,
  payer pubkey, payment hash, preimage, or only generic transaction fields?
- How long should new clients support incoming legacy claimable `PAY` lines?
