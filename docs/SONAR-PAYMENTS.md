# Sonar Payments — the ⚡PAY convention

Status: v1 (June 2026). UI: `bitchat/Views/Sonar/SonarPayViews.swift`,
protocol/state: `bitchat/Views/Sonar/SonarPayLedger.swift`, wallet
abstraction: `bitchat/Views/Sonar/SonarWalletStore.swift`. Design source of
truth: `design/handoff/project/sonar/pay.jsx` + the `.pay-*` styles in
`theme.css` (gold tokens).

## Idea: money as a message

A payment in Sonar is a **sealed coin** that travels inside a normal
end-to-end-encrypted chat message, over whatever rail the conversation is
using right now — Bluetooth mesh in range, internet (NIP-17 or White
Noise/Marmot) otherwise. The receiver sees a sealed gold card ("Payment
from X · Tap to claim"); the actual sats settle **over Lightning at claim
time**, not at send time.

## Wire format

⚡PAY lines are plain UTF-8 strings inside the existing encrypted chat
content — no new packet types, no transport changes. Field separator `|`:

```
⚡PAY|1|<uuid>|<sats>              sealed coin (sender → receiver)
⚡PAYCLAIM|1|<uuid>|<bolt12offer>  claim (receiver → sender)
⚡PAYDONE|1|<uuid>                 settled (sender → receiver)
```

- `1` is the protocol version. **Unknown versions render as plain text** —
  nothing is hidden, nothing breaks.
- `<uuid>` identifies one payment across all three lines (hex digits and
  dashes, ≤64 chars; senders use a lowercased UUIDv4).
- `<sats>` is a positive integer.
- `<bolt12offer>` is a BOLT12 offer created by the receiver's wallet;
  bech32 never contains `|`.

**Capability gating:** ⚡PAY lines are only ever sent to counterparts that
speak them — Marmot (White Noise) chats and Sonar peers whose discovery
announce sets capability **bit 1 = payments** (see `SONAR-DISCOVERY.md`).
Never to bitchat-only peers, whose clients would show the raw codec text.

## Settlement flow

```
sender                                   receiver
──────                                   ────────
ledger: outgoing sealed
⚡PAY ───────────────────────────────────▶ ledger: incoming sealed
                                          [sealed card, pulsing ₿ — tap]
                                          wallet.createOffer()
                                          ledger: sealed → claiming
ledger: sealed → settling  ◀───────────── ⚡PAYCLAIM
wallet.send(offer, sats,
  note: "Sonar payment <uuid>")
ledger: settling → claimed
⚡PAYDONE ───────────────────────────────▶ ledger: claiming → claimed
["Claimed by X"]                          [payPop reveal,
                                           "Added to your balance"]
```

Failure handling: if `createOffer` or the Lightning `send` throws, the
ledger reverts to `sealed` so the claim can be retried. Re-processing
control lines (transcript replay after relaunch) is harmless because every
ledger transition is an explicit, idempotent state machine.

## What is honest (deliberate deviations from the demo)

- **Balance is NOT deducted at send.** The demo decremented a fake balance
  when the coin was sent; in reality nothing leaves the wallet until the
  receiver claims and the sender's wallet pays the BOLT12 offer. The
  balance shown everywhere is the live wallet balance.
- **Fiat lines only render with a live rate.** `SonarWalletProviding
  .fiatText(forSats:)` returns nil when no live exchange rate is available
  and the € line simply doesn't render. Never a hardcoded rate.
- **No wallet, no pretending.** With `UnconfiguredWallet` (the default
  until `Services/WalletBridgeService` is glued in), Settings shows a
  "Set up" affordance and claiming/sending opens a sheet explaining that a
  wallet is needed.
- The sealed coin is a **promise riding the chat transport**, not bearer
  money: today the receiver must be online (relative to the sender) for
  Lightning settlement at claim time. The "ecash over Bluetooth" copy in
  the PaySheet is the design's North Star, not yet the mechanism.

## Local state: SonarPayLedger

Every coin this device sent or received lives in UserDefaults JSON
(`sonar.pay.ledger.v1`): `{id, peerKey, sats, direction, state, via}` with
`state ∈ sealed/claiming/settling/claimed` and `via ∈ mesh/internet` (the
rail the coin traveled, which is what the bubble's transport icon shows).
The emergency wipe clears the ledger.

## Future: offline ecash

The mesh rail is designed to carry true bearer ecash (e.g. Cashu-style
tokens minted against the wallet) so a coin can be claimed fully offline,
phone-to-phone. The ⚡PAY framing already accommodates this: a future
version bumps the payload (`⚡PAY|2|…`) and old clients degrade to plain
text rather than mis-rendering.
