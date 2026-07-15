# Brainstorm: Unified handles — `vincenzo@sonarprivacy.xyz` for chat + payments

Date: 2026-07-15

## Clarified Problem Statement

**Goal:** One claimable handle (`vincenzo@sonarprivacy.xyz`) that resolves to both the user's Nostr pubkey (NIP-05, for starting chats) and their BOLT12 offer (BIP-353, for payments), with Telegram-style bare-nickname UX inside Sonar: typing just `vincenzo` resolves against the default `sonarprivacy.xyz` domain, while full `name@domain` works for any external NIP-05/BIP-353 domain.

**Confirmed decisions (from Q&A):**

- One handle claim covers **both** chat identity and payment address, served by extending the existing bip353-registrar.
- **Claim + resolve** are both in scope: users claim their handle in-app; everyone can resolve handles. Registrar must be deployed for `sonarprivacy.xyz`.
- Bare `vincenzo` ⇒ `vincenzo@sonarprivacy.xyz`; full `alice@other.com` ⇒ standard NIP-05 lookup on that domain.
- Resolution surfaces: **start-chat search**, **wallet send screen**, and **profile display/verification badge** — on both iOS and Compose.

**Constraints:**

- Cross-Platform Feature Rule: ship on `ios/` and `apps/sonar/` together (or document the gap).
- XChat-Style Chat Startup Rule: starting a chat by handle may need one network resolution round-trip, but once the pubkey is known, chat creation must be instant/local-pending as today. The resolution step itself must be bounded (timeout), cancellable, and must never block existing local search results from painting.
- Account Key Durability Rule: handle ownership is authenticated by the identity key (kind-23353 signed event). Restore-from-nsec must be able to re-assert/recover the handle; the claim flow must never touch or regenerate the account key.
- Security: NIP-05 resolution MUST verify the returned pubkey maps back to the queried name (case-insensitive local-part, per NIP-05), and profile badges must only show when `nip05` in kind-0 verifies against the profile's pubkey. Never trust the display string alone.
- Handle normalization: lowercase `a-z0-9-_.` local parts (NIP-05 charset), enforced client-side before claim.
- Local Secrets Rule: registrar deploy tokens (Cloudflare) stay out of the repo.
- Current `bip353` prefs string on iOS ([SonarAppStore.swift:2160](../../ios/bitchat/Views/Sonar/SonarAppStore.swift)) is free-text and BLE-announced; the claim flow replaces/validates it — don't leave two divergent sources of the user's address.

**Non-goals:**

- Paid/premium handles, handle marketplace, or squatting policy beyond first-come-first-served.
- Nickname search across arbitrary relays (NIP-50 fuzzy people search) — bare nick is strictly default-domain lookup.
- LNURL/lightning-address (LUD-16) support — payments stay BOLT12/BIP-353.
- Multi-handle per account, handle transfer between keys.
- Changing the existing invite-link flow.

**Success criteria:**

- From Profile screen (both apps): claim `vincenzo` → registrar returns success → DNS TXT exists at `vincenzo.user._bitcoin-payment.sonarprivacy.xyz` AND `https://sonarprivacy.xyz/.well-known/nostr.json?name=vincenzo` returns the npub's hex pubkey.
- Kind-0 profile republishes with `nip05: vincenzo@sonarprivacy.xyz` after successful claim, so external Nostr clients show verification.
- Search screen (both apps): typing `vincenzo` or `vincenzo@sonarprivacy.xyz` or `alice@nostrplebs.com` shows a "Start secure chat" row after resolution; tapping creates the local pending conversation instantly (existing path).
- Wallet send (both apps): entering `name@domain` resolves BIP-353 → BOLT12 offer and pays (Breez SDK `parse()` already handles BIP-353 input — verify and wire through).
- Profile/contact screens show a verified-handle badge only when NIP-05 verification passes.
- Restore from nsec on a new device: handle re-attaches (registrar recognizes the same signing key; re-claim of your own handle is idempotent).
- No regression in cold-start bench (`scripts/bench/`): claim/resolve is user-initiated network work, never on the startup path.

## Approaches Considered

### Approach A: Extend bip353-registrar into a unified handle service (server-authoritative)

- Sketch: Add a `GET /.well-known/nostr.json?name=<local>` route to the existing Cloudflare Worker (bitvault-pay `services/bip353-registrar`), backed by the same `HandleRegistry` Durable Object — the kind-23353 claim event already carries the signer pubkey, so the registry has everything it needs. In Sonar core, add a `resolve_handle(input) -> {pubkey, bolt12?}` function (HTTP fetch + NIP-05 verification) and a `claim_handle(name)` function (build/sign kind-23353 with the BOLT12 offer, POST to registrar) exposed over FFI. Apps add: claim UI on the profile screen (replacing the free-text bip353 field), handle acceptance in search-screen chat-start, `name@domain` in wallet send, and verified badge rendering.
- Affected files:
  - External: `bitvault-pay/services/bip353-registrar` (new route + wrangler env for sonarprivacy.xyz; deploy per [docs/bip353-registration.md](../bip353-registration.md))
  - `core/sonar-core/src/` new `handles.rs` (claim + resolve + NIP-05 verify), `core/sonar-ffi/src/lib.rs`
  - iOS: `ios/bitchat/Views/Sonar/SonarProfileScreen.swift`, `SonarAppStore.swift` (bip353 field → claimed handle state), `SonarSearchScreen`-equivalent chat-start path, wallet send screen, `SonarContactProfileScreen.swift`
  - Compose: `apps/sonar/composeApp/.../screens/SonarProfileScreen.kt`, `SonarSearchScreen.kt`, wallet send screen, `SonarContactProfileScreen.kt`, `SonarCore.kt` FFI surface
- Tradeoffs: one claim = one identity for pay + chat (exactly the ask); resolution logic lives once in Rust core so both apps behave identically; requires cross-repo work and a registrar deploy (Cloudflare zone + DNSSEC for sonarprivacy.xyz); server is a trust point for name→key binding (mitigated by client-side NIP-05 verification and the signed-claim model).
- Effort: L (core M + two app surfaces M + registrar S + deploy/ops S)

### Approach B: Resolution-only client work, static/manual registration

- Sketch: Host a static `nostr.json` on sonarprivacy.xyz (even via the existing `web/` static hosting), register handles manually out-of-band. Apps implement only the resolve path (bare nick → default domain, full address → any domain) in core + search/wallet/profile surfaces. Claim flow deferred to a follow-up.
- Affected files: same client files as A minus the claim flow and registrar changes; plus a static file deploy.
- Tradeoffs: much faster to ship the user-visible resolution UX; but contradicts the confirmed "claim + resolve" scope, doesn't scale past a handful of manual entries, and leaves the payments TXT record unpopulated unless also done by hand.
- Effort: M

### Approach C: Nostr-native discovery (kind-0 + relay search, no registrar)

- Sketch: Resolve bare nicknames by querying NIP-50 search relays for kind-0 profiles whose `name` matches, then verify any advertised `nip05` bidirectionally before offering the chat. No server owned by us.
- Affected files: core resolver querying search relays; same app surfaces.
- Tradeoffs: zero infrastructure; but no unique handles (multiple `vincenzo`s → disambiguation UI), search relays are unreliable, and it cannot answer BIP-353 payments at all — fails two of the three confirmed surfaces.
- Effort: M

## Recommendation

Approach A. The registrar, auth model (signed kind-23353), and domain already exist by design in [docs/bip353-registration.md](../bip353-registration.md) — extending it with a `nostr.json` route is a small server delta that buys the exact Telegram-handle UX requested, and putting claim+resolve in Rust core keeps iOS/Compose behavior identical per the cross-platform rule. Suggested sequencing to de-risk: (1) registrar route + deploy, (2) core claim/resolve FFI, (3) app surfaces (search → profile claim → wallet), so resolution can be tested against a manually-seeded handle before the claim UI lands.

## Open questions

- Does the Breez SDK version in-tree already parse BIP-353 `name@domain` input in `parse()`? (Determines whether wallet-send needs its own DNS resolution or just input plumbing.) Verify before planning the wallet surface.
- Handle conflicts on restore: if the registrar sees a claim for an already-owned name from the same pubkey it should be idempotent — confirm the existing HandleRegistry behavior.
- Rate-limiting / abuse on the open claim endpoint (first-come-first-served floods) — registrar-side concern, may already exist in bitvault-pay.
- Should the BLE announce `bip353` field start carrying the claimed handle automatically post-claim (it's free-text today)?
- Web presence: should `sonarprivacy.xyz` serve a human landing page alongside `.well-known`, or stay bare?
