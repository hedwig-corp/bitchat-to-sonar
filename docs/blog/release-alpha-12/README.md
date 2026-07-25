---
title: v0.1-alpha.12 — one name to chat, one name to pay
cat: Engineering
date: 2026-07-25
summary: Sonar's biggest release yet: one @sonarprivacy.xyz handle now starts an encrypted chat (NIP-05) and receives Lightning payments (BIP-353) from any wallet — plus a production cutover to Signal-style transcripts, the Trill nudge, and mesh/group security fixes from an adversarial review.
author: The Sonar team
read: 4 min read
feature: false
---
# v0.1-alpha.12 — one name to chat, one name to pay

Sonar's biggest release so far answers one stubborn question: why should you need one identity to message someone and a completely different one to pay them? Alpha.12 collapses that into a single handle, cuts over to a Signal-shaped chat engine across both apps, and hardens the mesh and group-join path after an adversarial review.

Roughly sixty commits and close to sixty pull requests landed between alpha.11 and now. Here is what shipped, and where to read deeper.

## One handle for encrypted chat and Lightning payments

The headline is [PR #282](https://github.com/hedwig-corp/bitchat-to-sonar/pull/282) — **unified handles**. Claim a single `name@sonarprivacy.xyz` once, and that string does two jobs:

- **Start an encrypted chat** — type a handle, Sonar resolves it over standard NIP-05 and opens a local-first pending conversation. No pasting `npub1…`, no social-graph search.
- **Receive Lightning payments** — the same claim feeds a BIP-353 DNS record, so any Lightning wallet can pay `name@sonarprivacy.xyz` over BOLT12 without anyone copying an invoice string.

Handle ownership stays the account key. The handle is a pointer, not a second identity — exactly the rule we laid out when we [shipped nicknames and NIP-05 handles](https://sonarprivacy.xyz/blog/#nicknames-and-group-links). The account is still the secret; the handle is just how humans point at it. Read the full design there.

## Signal-shaped transcripts, in production

Opening a chat no longer waits on the network or rebuilds on every keyboard frame. [PR #338](https://github.com/hedwig-corp/bitchat-to-sonar/pull/338) cut Sonar over to the Signal-style transcript engine we had been dogfooding: pre-measured cells, sticky day headers, and the **pin / lockstep / ignore** scroll contract that keeps you glued to the live edge when the composer inset changes. It shipped on iOS and Compose in the same change.

If you want the why-we-extracted-and-then-did-not-publish story — shared golden fixtures, monorepo twin packages, and why we dogfood before freezing a public Maven/SPM API — [the transcript-engine dogfood post](https://sonarprivacy.xyz/blog/#transcript-engine-dogfood) is the deep dive.

## Trill: the nudge is back

We could not ship this much chat work and skip the fun part. [Trill (#336)](https://github.com/hedwig-corp/bitchat-to-sonar/pull/336) is an MSN-style nudge — a shake and a ⚡ for the contact who needs reminding you are still waiting. It is small, it is per-chat mutable, and it has its own [deep-dive post](https://sonarprivacy.xyz/blog/#trill-nudge).

## Hardened after an adversarial review

An external pentest came back with three classes of forgery and flooding against the mesh and group path. They are fixed in the #411 / #414 / #422 set:

- **Join-request spoofing** (#411) — join requests are now bound to the gift-wrap seal author, and hostile sync timestamps are clamped, so a forged request cannot masquerade as a real member.
- **Invite flooding** (#414 / #415) — the join and invite paths are rate-bounded, so a hostile peer cannot spam a group with requests or invite storms.
- **Mesh broadcast forgery** (#422) — signed broadcast frames are validated, so a relayed packet cannot be reborn as a forged announcement.

The thread underneath held: keys are identity, links are credentials. We just had to close the gaps where an attacker could abuse the *transport* to lie about who they were.

## Mesh and background delivery, more reliable

The offline road got real-world fixes this cycle:

- **Backgrounded Android no longer stops delivering** — the mesh stayed alive while the app was foregrounded but went silent in the background. Not anymore (#354).
- **Mesh DMs stop vanishing** (#397) — when BLE dropped mid-conversation, a DM could disappear from the chat row. It is preserved now, with the local echo rendered even when the live route is gone.
- **BLE delivery (#312)** and the iOS orphan-on-address-rotation sibling (#405) round out the set.

The product rule did not change — open from local storage first, sync in the background — but the background updater is now much less likely to drop your messages on the floor.

## Get it

Alpha.12 is rolling out now.

---

*Sonar is free and open source. [Read the docs](Sonar%20Docs.html) or [get the app](Sonar%20Landing.html).*
