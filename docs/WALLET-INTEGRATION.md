# Wallet integration

Sonar's wallet is a **Cashu (ecash) wallet**, for every user, on every app
surface. The **Breez** Lightning wallet that shipped before it is kept as a
**legacy** wallet: it is never created for a new install, and it stays
visible, spendable, and user-deletable once its funds are provably safe.

Decided 2026-09-23 (maintainer). The earlier Breez→Cashu migration engine
and its consent UX are parked on #586 and are not part of the shipping app.

## Custody model

Ecash proofs are bearer instruments held in a local per-account store; the
**mint** (`https://mint.hedwig.sh`, cdk-mintd) holds the Lightning side. The
user trusts the mint with the funds it backs. That trade is disclosed in
Settings ("Held as ecash at mint.hedwig.sh"); there is no activation gate.

What the nsec alone can recover:

- **Minted proofs**: yes. Proof secrets derive from the Cashu seed (NUT-13),
  and `connect()` runs a restore scan whenever one is owed: a new device, a
  wipe, or a lost proof db (R-050).
- **The published offer's pending payments**: yes, while the pointer file
  survives. The offer's NUT-20 key is derived, not random, so `connect()`
  re-adopts its quote after the proof db is lost.
- **Sats paid to a quote but not yet minted, after a full reinstall**: no.
  The quote id is gone with the store; the funds sit at the mint.

## Layers

```
apps (Swift / Kotlin)              wallet facade, balance cache, offer publication,
                                   legacy Breez card, wipe/replace policy
        │ UniFFI (blocking calls; never on the UI thread)
core/sonar-ffi   wallet.rs         SonarCashuWallet, CashuWalletListener,
                                   WalletFfiError, fetch_fiat_rates()
core/sonar-wallet-cdk              CdkWallet: the WalletBackend over CDK 0.18.1
                                   (cdk + cdk-redb; no sqlite, so a normal
                                   workspace member)
core/sonar-wallet                  WalletBackend trait, seeds, destination
                                   classification, wipe guard, rates parsing
```

The Breez backend never enters `sonar-ffi`: `breez-sdk-liquid` ships a forked
`libsqlite3-sys` (`links = "sqlite3"`, plain SQLite) that cannot share a cargo
graph or a binary with the SQLCipher store (the symbol-shadowing class that
once broke iOS Marmot encryption). The apps keep Breez on their existing
native SDKs; `core/sonar-wallet-breez` is a separate build island with a
headless CLI.

## Seeds (wallet identity: never change these)

| Wallet | Derivation | Pinned by |
| --- | --- | --- |
| Breez (legacy) | HKDF-SHA256(nsec secret, salt `sonar-wallet`, info `sonar-bolt12-v1`, 32 B), raw seed, never BIP39 | `seed.rs::entropy_matches_ios_golden_vector` + `SonarWalletDerivationTests` |
| Cashu | HKDF-SHA256(nsec secret, salt `sonar-wallet`, info `sonar-cashu-v1`, 64 B) | `seed.rs::cashu_seed_matches_golden_vector` |
| Cashu offer NUT-20 key | HKDF-SHA256(cashu seed, salt `sonar-wallet`, info `sonar-cashu-offer-nut20-v1` ‖ 0 ‖ mint url ‖ 0 ‖ index u32 BE, 32 B) | `seed.rs::cashu_offer_key_matches_golden_vectors` |

## Store layout

`<root>/sonar-cashu/<accountId>/mainnet`, where `accountId` is the lower-case
hex of the first 16 bytes of SHA-256(nsec as UTF-8). Root: iOS Application
Support (the app's own container, never the App Group, because of 0xdead10cc);
Android `filesDir`; desktop `DesktopEnv`. The store refuses a different
account's seed (an `O_EXCL` `cashu.account` claim), so the directory MUST be
per account.

Files the wipe guard recognises (anything else in the dir blocks a wipe):
`cashu.redb`, `cashu.account`, `cashu.restored.<mint8>`,
`cashu.offer.<mint8>` (+ `.tmp`), and the reserved `cashu.migration.v1.*`
names of the parked migration.

## The FFI contract (`core/sonar-ffi/src/wallet.rs`)

Every call blocks. Call it from a background executor.

- `SonarCashuWallet(nsec, mint_url, working_dir)`: local only, no network.
- `connect()`: mint info, NUT-13 restore when owed, recovery of melts/swaps a
  crash interrupted, then the 5 s watcher. Idempotent, `Busy` while another
  connect runs. Bounded: a hung mint yields `Timeout`, never a stuck call.
- `receive_offer()`: **the** receive address hosts publish (descriptor,
  BIP-353, BLE, Unify). One reusable amountless BOLT12 quote; stable across
  calls and launches; answered from disk with no network once created.
  Rotates only when the quote expires (the old quote keeps minting). A mint
  that forgets the quote is indistinguishable from an outage and does not
  rotate.
- `receive_invoice(amount, description?)` returns a one-time BOLT11 invoice
  and the `payment_id` its payment will arrive under, so a host can stop
  showing a paid invoice as payable.
- `prepare_send(dest, amount?)` returns the mint's amount and fee RESERVE.
  Show it before consent. `send(prepared, note)` is the one spending call.
  A fee quote for display is a `prepare_send` whose result is discarded: it
  reserves nothing, and `send` prepares again.
  **`Pending` is not a failure**: past its deadline, or with a mint still
  routing, the payment is reported Pending and its outcome arrives as an
  event with the same `id`. Never retry a Pending send with a new quote; that
  can pay twice. A confirm error is only Pending when the mint's own quote
  state says so: a quote the mint reports Unpaid or Failed (including a melt
  saga recovery rolled back) is Failed, and `lookup_payment` answers from the
  mint's melt quote when history no longer shows the send.
- Every payment to the offer is its own payment: `{quote_id}:{tx_id}`.
- History carries the preimage (chat `⚡PAYDONE|2` needs it after a restart).
- Errors: `WalletFfiError` is non-flat; branch on `InsufficientFunds`,
  `NotConnected`, `Network`, `Timeout`, never on message text.
- `fetch_fiat_rates()`: Yadio (`api.yadio.io/exrates/BTC`), about 145
  currencies, no key, 10 s bound. Independent of any wallet.

## Apps

| Concern | Apple (`ios/`) | Compose (`apps/sonar/`) |
| --- | --- | --- |
| Primary wallet | `CashuWalletService` + `CashuWallet` (`SonarWalletProviding`), FFI on one serial utility queue | `CashuWalletEngine` behind the `WalletBridge` object, FFI on `Dispatchers.IO` via `CashuNative` actuals |
| Legacy wallet | `LegacyBreezWallet` + `SonarLegacyWalletCoordinator` | `expect object LegacyBreezWallet` + `LegacyBreezStore` |
| Display prefs | `SonarMoneyDisplay` (UserDefaults, copied once from the Breez Keychain) | `WalletDisplayPrefs` (already app-owned) |

Shared behaviour, pinned by tests on both platforms:

- The wallet opens after local paint. The cached balance and the offer (from
  disk) publish first, then connect retries with backoff. The app connects on
  foreground and disconnects on background, never under a send in flight.
- "Payments enabled" and the BLE payments capability mean "a Cashu offer
  exists for this account", with no dependence on a Breez key.
- The descriptor, BIP-353 handle and Unify use the Cashu offer and republish
  when it changes. Difference: while an account has no offer yet, Apple skips
  publishing, while Compose publishes the descriptor with no offer, so a
  restored device stops advertising an offer only the old device can mint.
- A send that returns Pending is recorded as pending and settled exactly once,
  by the outcome event or by a lookup after reconnecting. A chat ⚡PAY sends
  neither its `PAY` nor its `PAYDONE|2|id|preimage` line until it settles, so
  a later failure never leaves a misleading receipt with the peer.
- `Max` on Cashu prepares at the full balance, subtracts the quoted fee reserve
  and prepares again. The 0.5% Breez reserve applies to the legacy wallet only.
- The Wallet screen has Receive and Send. Receive shows the reusable offer
  (QR, Copy, Share) or, for "Request an amount", a one-time invoice; once
  that invoice's own payment arrives (matched by `payment_id`, never by
  amount) the sheet goes back to the offer.
- The send sheet shows the mint's fee reserve ("Network fee: up to …") before
  the user confirms, re-quoted 400 ms after the amount settles. The quote
  never connects the wallet and never blocks Send; on any error the line
  hides.

## Legacy Breez

- Opened only when its store already exists on the device. A restored account
  gets ONE background check (builds with a Breez API key only): if the derived
  Breez wallet has funds or history it is kept as legacy, otherwise what the
  check created is deleted.
- Its NDS webhook / `invoice_request` push path stays alive only while it
  exists, against its own offer (never the published Cashu offer).
- **Delete gate**, all of: connected with a completed sync; confirmed,
  pending-send and pending-receive all 0; no refundable swaps; no
  Pending/Refundable payments. Anything unknown means not safe.
- Balances under ~1,000 sats cannot leave over Lightning (the Boltz submarine
  swap minimum), so they stay visible and undeletable until spendable.

## Wipe and account replacement

- **Panic wipe** deletes everything wallet-related, every `sonar-cashu/` root
  included. Minted proofs remain restorable from the nsec; sats paid to a
  quote but not yet minted do not.
- **Account replacement** never destroys a wallet that may hold funds: the old
  account's `sonar-cashu/<accountId>/` stays on disk, and a legacy Breez store
  that fails the delete gate is archived rather than deleted.

## Testing

`core/sonar-wallet-cdk/src/test_mint.rs` is an in-process fake mint (a
`MintConnector` with a real keyset, real blind signatures, NUT-09 restore,
NUT-20 enforcement, scripted melt outcomes, and injectable failures, delays,
and hangs). Tests drive the real `connect`/watcher/`send` paths through
`CdkWallet::with_connector`; `sonar-ffi` reuses it through the
`test-support` feature. An in-process CDK *mint* is not an option: its
database would bring bundled SQLite into the SQLCipher graph.

Live-sats tests (receive via the offer, pay a BOLT11, a chat ⚡PAY with
preimage) run only on explicit approval of the amounts.

## Known gaps

- No push notification for a Cashu receive while the app is killed. Funds
  wait at the mint and are minted on the next foreground. Follow-up: bridge
  the mint's quote-paid events (NUT-17) to push.
- A full reinstall loses the offer pointer; payments to the old offer sit at
  the mint. Follow-up: carry the offer quote id in the sealed account backup.
- **One active device per account.** An account cannot run on two devices at
  once today; that needs Marmot protocol work first (maintainer, 2026-09-23).
  The Cashu wallet inherits the constraint. When multi-device lands, the wallet
  needs its own design: both devices derive the same Cashu seed, and NUT-13
  derives proof secrets from seed + counter, so two live stores would reuse
  blinded outputs. The mint rejects the second device's mints and swaps, and a
  restore can leave both devices holding the same bearer proofs. Breez synced
  across devices; Cashu does not. Options then: a single wallet device,
  per-device seeds, or a counter resync on `AlreadySigned`.
- Existing installs already carry a Breez seed, so they run a legacy Breez node
  every launch until the user deletes it, even when it is empty.
- A store that is already corrupted is not rebuilt: connect fails on every
  retry and the wallet reads "Mint offline — retrying". The funds stay at the
  mint and a NUT-13 restore into a fresh store would recover them. The one
  path found that corrupts it (two redb writers, Android) is closed.
  Follow-up: move a corrupted `cashu.redb` aside and restore, and say so.
