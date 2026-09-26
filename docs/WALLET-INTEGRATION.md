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
  BLE, Unify, and the BIP-353 handle once it pays this wallet: see "The
  handle's payment address"). One reusable amountless BOLT12 quote; stable across
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
- The descriptor and Unify use the Cashu offer and republish when it
  changes. Difference: while an account has no offer yet, Apple skips
  publishing, while Compose publishes the call descriptor alone. Neither
  withdraws an offer already on the relays: `descriptor_events`
  (`core/sonar-core/src/sonar_descriptor.rs`) emits the `sonar.meta.v1`
  event, which carries the offer, only when there is an offer, because
  republishing it empty would replace a good offer with nothing. That is
  deliberate; do not "fix" it to clear the offer. The public BIP-353 handle
  follows the Cashu offer only under the rules in "The handle's payment
  address"; its registration never gates the descriptor publish.
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

## The handle's payment address

The handle (`name@sonarprivacy.xyz`) is a public address: it can be printed
or shared outside the app, and the registrar
(`services/handle-registrar/src/registry.ts`) points its BIP-353 DNS TXT at
whatever offer the last claim carried. Before Cashu that was the Breez
wallet's offer. Retargeting it at the Cashu offer moves future payments into
custody at `mint.hedwig.sh`, so the app never does that on an update. (The
in-app descriptor is a different surface: it always carries the Cashu offer.)

Per account the app records which wallet the handle pays (`legacy` |
`cashu`, absent = not known yet) and the offer last registered with it
(iOS: `UserDefaults` `sonar.handle.addressWallet.<npub>` /
`sonar.handle.registeredOffer.<npub>`; Compose: `CoreWalletPrefs`
`wallet.handle.pays.<accountId>` / `wallet.handle.registeredOffer.<accountId>`).
The decision is one pure function on each platform
(`SonarHandleOfferPolicy.action` / `handleOfferAction`):

| Recorded | Legacy wallet on this device | Result |
| --- | --- | --- |
| `cashu` | any | re-register when the Cashu offer differs from the one registered |
| `legacy` or absent | present | **ask**: "Your address … still pays your old wallet." + Move |
| `legacy` or absent | not established yet | nothing, until it is |
| `legacy` or absent | absent (new install, or the old wallet deleted) | re-register with the Cashu offer |

- **Legacy presence** is "absent" only once established: the presence check
  ran and no post-restore check that could still keep a Breez wallet is
  pending (in a build with a Breez key). A Keychain that cannot answer, an
  archive that failed to come back, or a restore check in progress are all
  "unknown", which never moves the handle.
- **Move** asks first: payments to the address will go to the new wallet,
  held as ecash at mint.hedwig.sh; the old wallet stays spendable; deleting
  the new wallet does not move the address back. Confirm → claim with the
  Cashu offer; success records `cashu`; failure shows the error and leaves
  the notice (the address still pays the old wallet).
- **Move back**: while the handle pays Cashu and the old wallet is here,
  "Move back to your old wallet" (confirmed) claims with the legacy wallet's
  OWN offer and records `legacy`. It needs the old wallet connected.
- **An explicit claim** (typing a name and claiming) registers the Cashu
  offer and records `cashu`; the claim field says where payments go.
- **A restore reclaim** (the sidecar is empty after an nsec restore) carries
  the Cashu offer only where the table says re-register; otherwise it is a
  chat-only claim, which seeds the sidecar and leaves the registrar's record
  as it is (a claim without an offer never changes the DNS TXT).
- **A failed automatic re-registration** shows "Couldn't update your address
  … Retrying." and retries with backoff (30 s doubling to 15 min).
- Registrar writes are serialized, so an automatic re-claim never races a
  Move.
- The notice is shown with the username (Profile; the Mac panes), in
  Settings under the wallet, and in the old wallet's card on the Wallet
  screen.

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

## Damaged store

A proof store that no longer opens (redb reports it corrupted, cannot read its
header, or panics opening it) is renamed `cashu.redb.corrupt-<secs>` — kept,
never deleted, and accepted by the wipe guard — and connect continues on a
fresh store: the NUT-13 restore rebuilds the funds from the seed and the offer
pointer re-adopts the stable offer. Any other open error (already open,
permissions, a newer file format) is surfaced, never a reason to set the file
aside. Before, every connect failed forever and the app read "Mint offline —
retrying" over recoverable funds.

## Offer backups

The stable offer's mint quote id lives only in the local pointer file, so a
reinstall used to publish a new offer while payments to the old one stayed at
the mint. `CdkWallet::offer_backup` exports the pointer (`{v, mint, quote_id,
offer, index}`); the hosts publish it to the account's relays through
`SonarNode.publishWalletOfferBackup`: kind 30078, NIP-44 sealed to the
account's own key (the quote id would show anyone the offer's received
amounts), one addressable event per backup (`d` = `sonar.wallet.offer.v1:` +
content hash) found through the `t` tag `sonar.wallet.offer.v1`, so a newer
offer never replaces an older one's backup. On a store with no pointer the
hosts first fetch every backup and call `restore_offer_backups`: the newest
becomes the offer (a local one is never replaced) and every backed-up quote the
store lacks is re-adopted, so payments to any of them are minted. Until that
fetch succeeds once per install, the hosts never create a new offer; "no relay
answered" is an error, never an empty list.

## Receive banner

A payment from outside Sonar (another wallet paying the offer or a one-time
invoice) has no chat line, so the app posts one "Payment received"
notification when it settles, deduplicated per payment id (iOS: the activity
ledger's first insert; Compose: the notified-payments ring the push service
also uses), respecting the notification settings.

A chat ⚡PAY is already announced by its chat line, and the wallet cannot tell
it from an outside payment: the payer pays the public offer, so nothing links
the payment to the receipt's uuid. `ReceiveAnnouncer` (Compose) /
`SonarReceiveAnnouncer` (iOS) pair them by amount, one receipt to one receive,
so the chat line stays the only notification (Signal's model: the payment
message is the notification):

- a receipt seen first silences the next receive of its amount within 24 h
  (the wallet mints only in the foreground, hours after a push-delivered ⚡PAY);
- a receive seen first waits 30 s for its receipt, then posts the banner;
- only receipts the pay ledger records for the first time count, sent within
  24 h and not our own, so a transcript replayed after a restart never
  silences a new outside payment.

## Known gaps

- No push notification for a Cashu receive while the app is killed. Funds
  wait at the mint and are minted on the next foreground, and the "Payment
  received" banner fires then. Follow-up: bridge the mint's quote-paid events
  (NUT-17) to push.
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
- A melt the mint settles internally (Sonar to Sonar on one mint, the common
  case) returns no preimage, so `⚡PAYDONE|2` carries none. The payment status
  copy therefore no longer claims a "cryptographic proof" on any payment.
  Follow-up: show the proof line again when a preimage did come back.
- A rebuilt store (see "Damaged store" above) loses what only the damaged
  file held: an in-flight send's quote and a one-time invoice paid but not yet
  minted. The stable offer comes back from its pointer; everything minted comes
  back through NUT-13. The damaged file is kept for inspection.
- The receive banner pairs a chat ⚡PAY with its payment by amount (see
  "Receive banner"), so: an outside payment's banner comes 30 s late; a
  receipt whose payment never reaches the Cashu wallet (paid to the legacy
  Breez wallet, say) can silence one outside receive of the same amount within
  24 h; a ⚡PAY that lands more than 30 s after its payment still announces
  twice; and two chat payments minted in one wallet poll arrive as one receive
  that neither receipt matches. An exact link needs the receipt to name the
  payment, which the mint does not expose per payment today.
- Offer backups need the account's relays: if none answers when a reinstalled
  wallet first connects, no offer is created until one does (retried every
  30 s), rather than publishing a new offer over the backed-up one.
- The handle's payment record is local to the device. After a restore onto
  a device that keeps a Breez wallet, the app does not know which offer the
  registrar holds, so it says "still pays your old wallet" even if the old
  device had already moved it (Move then re-registers the same Cashu offer).
  A handle that was a chat-only claim with a Breez wallet present also reads
  "still pays your old wallet" although it pays nothing. Reading the live
  BIP-353 record (a DNS TXT lookup of
  `<name>.user._bitcoin-payment.<domain>`) would settle both; the apps do
  not do that lookup today. Follow-up: compare the live record with the two
  wallets' offers before showing the notice.
