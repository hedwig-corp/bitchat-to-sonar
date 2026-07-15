# Nsec restore: discoverable + wallet rebuild + Settings path

Date: 2026-07-15
Status: clarified — shipped in this PR
Answers: 1A (couldn't find restore), 2B (onboarding + Settings), 3A (always wipe wallet → rebuild from nsec)

## Clarified Problem Statement

**Goal:** Make nsec restore obvious and correct on iOS and Android: identity + Lightning wallet always rebuild from the pasted nsec, from onboarding and from Settings.

**Constraints:**
- Cross-platform (`ios/` + `apps/sonar/`).
- Always wipe existing wallet material before creating from restored nsec (3A).
- Account Key Durability: never silent regenerate; restore is explicit user paste.
- No Blossom chat backup in this change.

**Non-goals:** Signal-like Blossom backup; mesh history; separate BIP39 UI.

**Success criteria:**
- Onboarding restore CTA is obvious.
- Paste valid nsec → same npub + wallet balance after Breez sync.
- Settings → Restore account works for already-onboarded users.
- Invalid nsec does not corrupt current account.

## Recommendation

Approach B: discoverability + wallet wipe on restore + Settings import.

## Implementation notes

- iOS: `BridgedWallet.rebuildFromIdentity()` + expanded `wipeWalletStorage()` (Keychain + breez dirs + App Group creds).
- Compose: `WalletBridge.wipeLocalStorage()`; restore path wipes then `boot()` → `setupWallet()`.
- UI: accent-soft restore CTA on onboarding; Settings restore sheet with confirm toggle.
