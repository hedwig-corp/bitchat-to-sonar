# Bitcoin wallet derived from the Sonar chat identity

Date: 2026-06-12
Status: clarified (brainstorm output, no code changes). Builds on PR #1 (commits on top).

## Context findings

- unify's `Bip39MnemonicGenerator` (libs/key-manager/impl) does
  `MnemonicCode.toMnemonics(entropy)` with `secureRandomBytes(16)`. Swapping the
  random entropy for entropy DERIVED from the Nostr secret yields a deterministic
  BIP39 mnemonic — `MnemonicCode.toMnemonics` is a pure function. So
  "one identity = one wallet" is a small change at the entropy source.
- The 0x53 Sonar discovery TLV already carries npub + bip353 + a capabilities
  bitfield whose bit1 = "speaks ⚡PAY / payments". TLV field lengths are 1 byte
  (max 255) and the announce rides a size-limited BLE packet — a full BOLT12
  offer (`lno1…`, ~300-700B) does NOT belong in the announce.
- The existing ⚡PAY flow already exchanges the offer IN-BAND: receiver creates a
  BOLT12 offer at claim time and returns it in `⚡PAYCLAIM`; sender pays it via
  `WalletBridgeService`. So proactive "put the offer in discovery" is unnecessary
  for payments to work — capability advertisement is enough.
- `WalletBridgeService` (mainnet default), `SonarWalletKit` (Breez Liquid
  on-device, Keychain seed), and `SonarIdentity` (can export the nsec/secret)
  already exist from PR #1.

## Decisions taken (user, 2026-06-12)

- Offer delivery: **capability bit + in-band exchange** (no offer in the BLE
  announce). The ⚡PAY flow covers it.
- Network: **mainnet now** (real sats; needs BREEZ_API_KEY on both devices).
- Backup: **derive from the nsec; the nsec IS the wallet backup.** Coupling
  accepted (nsec compromise = funds compromise).

## Clarified Problem Statement

**Goal:** Deterministically derive the Breez/Unify BOLT12 Lightning wallet from
the Sonar identity's Nostr secret so one identity = one reconstructable wallet,
with in-chat Sonar-to-Sonar payments.

**Constraints:**
- Wallet mnemonic = deterministic function of the Nostr secret via a
  domain-separated KDF (HKDF-SHA256, fixed salt/info e.g. `sonar-bolt12-v1`);
  reconstructable from the nsec alone.
- No BOLT12 offer in the BLE announce — advertise the payments capability
  (0x53 TLV bit1, already present); exchange the offer in-band, encrypted, in
  the ⚡PAY flow.
- Mainnet; requires BREEZ_API_KEY on both devices.
- Payments only between Sonar / protocol-supporting peers (never to plain
  bitchat).
- Coupling accepted: nsec holder controls chat + funds.
- Commits on top of PR #1.

**Non-goals (for now):**
- Supporting Unify's own discovery/payment protocol to pay Unify users directly
  (explicit future work).
- Full offer over BLE; separate offer-request protocol; wallet multi-device.
- BIP-353/DNS as a payment channel.

**Success criteria:**
- Reinstall (same nsec) → same wallet/balance, proven by a derivation test.
- Two Sonar users exchange sats in chat E2E on mainnet.
- A peer advertising the payments capability shows "Send sats" enabled; plain
  bitchat never does.
- Panic wipe erases the derived seed (still reconstructable from the nsec).

## Approaches Considered

### Approach A: Swift-side derivation (CryptoKit HKDF) + deterministic wallet-kit import
- Sketch: `WalletBridgeService` reads the Nostr secret from `SonarIdentity`,
  computes `HKDF-SHA256(secret, salt:"sonar-wallet", info:"bolt12-v1")` → 32B →
  passes it to a new deterministic path in SonarWalletKit
  (`KeyManager.deriveAndStoreMnemonic(entropy)` replacing the random generator).
  Mainnet.
- Affected: `bitchat/Services/WalletBridgeService.swift`,
  `localPackages/SonarWalletKit/Sources` (entropy init), unify
  `libs/key-manager` on branch `sonar-wallet-kit` + rebuild xcframework.
- Tradeoffs: Swift already bridges identity + wallet → least new FFI, HKDF is
  trivial. The 32-byte secret transits Swift in the clear (`SonarIdentity.nsec`).
- Effort: M.

### Approach B: Rust-core derivation (HKDF + BIP39), exposed over FFI
- Sketch: `sonar-core` derives entropy from the secret it already holds (never
  leaves Rust) and produces the mnemonic with a BIP39 crate; FFI
  `derive_wallet_mnemonic() -> String`; Swift hands it to wallet-kit.
- Affected: `core/sonar-core` (+ bip39 crate), `core/sonar-ffi`, rebuild
  SonarCore xcframework, `WalletBridgeService`.
- Tradeoffs: Nostr secret stays confined to Rust (better hygiene). But the
  mnemonic still crosses FFI to reach Breez; more surface (new Rust dep, two
  xcframeworks to regenerate).
- Effort: M/L.

### Approach C: Kotlin wallet-kit derivation (pass the secret into wallet-kit)
- Sketch: pass the Nostr secret into SonarWalletKit; derivation (HKDF +
  bitcoin-kmp) happens in Kotlin next to the MnemonicGenerator.
- Affected: `localPackages/SonarWalletKit` / unify branch + `WalletBridgeService`.
- Tradeoffs: all wallet logic in one place. But letting the chat secret into the
  wallet module mixes domains and duplicates the KDF.
- Effort: M.

## Recommendation

**Approach A.** Swift is already where identity (`SonarCore`) and wallet
(`SonarWalletKit`) meet; CryptoKit HKDF is one line; the only new wallet-kit
piece is an entropy-based init replacing the random generator — minimal surface,
no new Rust xcframework. Approach B's hygiene argument (secret confined to Rust)
is valid but weak: the mnemonic must cross the boundary anyway to reach Breez. If
a tight key-handling audit is wanted later, the KDF can move to Rust without
changing the Swift interface.

## Open questions

- Mnemonic length: 16B/12 words (unify today) or 32B/24 words to not discard
  entropy? (Recommend 24 words.)
- Payments-capability gating in the announce: always on, or only when the wallet
  is actually configured (BREEZ_API_KEY present)? (Recommend: only when
  configured, so "Send sats" never appears toward a peer that can't receive.)
- "Protocol supporters" beyond Sonar = for now only 0x53 peers with the payments
  bit; the Unify-discovery bridge stays future work.
