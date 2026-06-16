# Brainstorm: capabilities on White Noise accounts (npub ≠ "Sonar-only")

**Date:** 2026-06-16

## Problem

A Sonar user **is** an npub — a **White Noise account** (Nostr identity). White Noise
(Marmot/MLS) text DMs work account-to-account over the internet for *any* npub. But the
app conflated "has an npub we learned over BLE" with "is a Sonar app", and layered extra
capabilities (payment, calls) that are exchanged **only over BLE** via the 0x53 announce.
That produced "Sonar-only" gating (e.g. "Send sats" only for `p.sonar`) and the framing of
npub holders as *Sonar peers* rather than *White Noise accounts*.

Goal: treat an npub as a White Noise account; stop gating functionality on "is a Sonar
app". Decide **where each capability lives** and **when it is exchanged**.

## The three layers (different in nature)

| Thing | Nature | Home |
|---|---|---|
| npub / White Noise text | durable account identity | the account (Nostr) — always, internet |
| Payment (BOLT12 / BIP-353) | a stable receiving address | **BLE 0x53, proximity-private + persisted** |
| Call info (iroh node) | a reachable endpoint | **stable, published in the Nostr profile** |

## Tension

Where capabilities live trades **proximity-consent + privacy** against **internet reach**:
- BLE-only = private, meeting is the consent gesture, but no reach after you part.
- Account-published = public, max reach, but discoverable by anyone.
- Hybrid = BLE discovers fast + we persist (like the fingerprint↔npub link), so it keeps
  working over the internet with contacts you've met — without publishing to public relays.

## Decisions (owner)

1. **Reach = hybrid (persist).** BLE discovers pay/call; we persist so it works later over
   the internet with met contacts. Same shape as the fingerprint↔npub link already built.
2. **Payment = proximity-private, BLE-only (for now).** The pay endpoint is exchanged via
   0x53 and persisted; it is NOT published to public relays. Paying an npub you've *never*
   met (public Nostr zaps / BOLT12) is a **separate future feature** → issue #24.
3. **Calls = stable endpoint in the Nostr profile.** Publish a stable iroh node id so you're
   callable anytime by anyone who has your npub.
4. **Text = account-level, always.** Any npub is White-Noise-reachable; drop the "Sonar
   peer vs not" gating on text continuation. `CAP_MARMOT` is redundant (any npub speaks
   Marmot).

## Implementation sketch (follow-up)

- **Reframe**: "Sonar peer" → "White Noise account" in code/UI; `isSonarPeer` means
  "we know their npub" = reachable over White Noise. Keep the BLE radar badge as
  "rich announce", not a capability tier.
- **Payment**: persist the BLE-discovered pay capability (BOLT12/BIP-353) per npub
  (alongside `sonar.links`); show "Send sats" whenever we have a *persisted* pay endpoint
  for that account, not only while `p.sonar` is live in range.
- **Calls**: publish the iroh node id in our kind-0 profile; resolve a callee's endpoint
  from their profile so calls work account-to-account (not BLE-gated).
- **Cleanup**: `CAP_MARMOT` gating can go; keep `CAP_PAY` only as a hint, with the
  persisted pay endpoint as the source of truth.

## Out of scope (tracked)

- Public Lightning payments via Nostr zaps / BOLT12 to an npub you've never met → **#24**.
