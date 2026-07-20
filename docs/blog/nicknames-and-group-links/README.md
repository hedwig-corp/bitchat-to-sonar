---
title: Nicknames, handles, and readable group links — names people can share without becoming the account
cat: Engineering
date: 2026-07-20
summary: Sonar separates free-form nicknames, claimable NIP-05 handles, and Signal-style HTTPS group invites so people stay discoverable and shareable — while the account key stays the only durable identity.
author: The Sonar team
read: 9 min read
feature: false
---

# Nicknames, handles, and readable group links — names people can share without becoming the account

Secure messengers inherit an awkward UX problem: the durable identity is a key, but humans refuse to paste `npub1…` into every chat. Sonar’s answer is not “make the nickname the account.” It is a small stack of presentation and discovery layers that stay subordinate to cryptography — plus group invites that look like ordinary HTTPS links instead of opaque custom schemes.

This post is the map of two product surfaces people hit every day: **what you call someone**, and **how you invite them into a group**.

## The rule under both features

**Keys are identity. Names are labels. Links are credentials.**

- Your account is the Nostr secret (`nsec` / `marmot-nsec`) and the Noise fingerprint on the mesh. Losing the secret loses the account; renaming does not mint a new one.
- A nickname is what peers see in a list. It can collide, change, and disagree across devices until kind-0 catches up.
- A handle (`name@sonarprivacy.xyz`) is an optional, unique pointer that resolves to a pubkey.
- A group invite link is a bearer capability to *request* membership. Opening it is not the same as being in the MLS group.

If a design ever lets a string overwrite a key, or lets a URL skip admin approval into an MLS epoch, it is wrong — even if the string looks friendlier.

## Nicknames: three labels, one person

Sonar does not ship one nickname system. It ships **three overlapping labels**, plus a **claimable handle**. Cryptographic identity stays authoritative; names are presentation and discovery.

### 1. Local nickname (device prefs)

On first launch the app may mint something like `anon####`. You rename it in onboarding or Profile. That string lives in local prefs and is what *you* believe your display name is until the network profile says otherwise.

After an `nsec` restore, an empty local nick is intentional: relaunch must not invent a fresh anon and republish it over a durable relay profile. Remote kind-0 wins. That invariant is load-bearing enough to sit in the regression ledger (R-010).

### 2. Mesh / BLE nickname (transport metadata)

Nearby peers learn a name from the BitChat identity announce TLV — nickname plus Noise and signing keys. Radar rows and mesh DMs show that string. Once a peer is folded into a White Noise / Marmot conversation, the BLE nick is treated as **transport metadata**, not as the conversation title. Mesh collisions get a short peer-id suffix so two `Alice`s in the room stay distinguishable.

Favorites can keep a local petname for when the peer is offline. That petname never leaves your device as identity.

### 3. Nostr kind-0 profile (NIP-01) — secure-chat display name

Marmot identity *is* a Nostr pubkey. Display names for internet / White Noise peers live in standard **kind-0 metadata**, not inside MLS. Publish sets both `name` and `display_name` to the same string; optional `about` / `picture` ride along. Peers fetch, cache by `npub`, and show `bestName` (`display_name` else `name`). Push banners in a killed app get a name-only App Group mirror so notifications do not fall back to raw fingerprints.

Kind-0 is replaceable. Publishing a blank or stale local nick, or omitting a claimed `nip05` on republish, can destroy the durable profile. Host apps therefore merge the handle from a core sidecar instead of trusting whatever string happens to be in prefs.

The publish path is deliberately fan-out: local prefs feed both the BLE announce TLV and a kind-0 republish; a claimed handle lives in a core sidecar and is merged into kind-0’s `nip05` field so a nick-only rename cannot wipe it. Peers read names from the local profile cache (and an App Group name map for killed-app push), not by treating the nickname as a second account key.

| Surface | What you see | Source of truth |
| --- | --- | --- |
| Your Profile name | Editable nick | Local prefs; after restore, remote kind-0 |
| Nearby / mesh row | Live announce (else favorite nick) | BLE TLV |
| Secure chat title / group author | Cached `bestName`, else short npub | Kind-0 fetch |
| Start chat by handle | Resolved pubkey → local pending chat | NIP-05 HTTP, not relay search |
| Killed-app push banner | Name map in App Group | No network in the extension |

## Handles: unique discovery without NIP-50 search

A free-form nickname is not unique and is not how you start a chat with a stranger across the internet. For that Sonar uses **handles**:

| Concern | Mechanism |
| --- | --- |
| Claim | Signed kind-`23353` request to the registrar (not gossiped as the chat identity) |
| Resolve | Standard NIP-05 `/.well-known/nostr.json?name=` |
| Payments | Same claim can feed BIP-353 DNS TXT |
| Bare name | Defaults to `sonarprivacy.xyz` (`vincenzo` → `vincenzo@sonarprivacy.xyz`) |
| Kind-0 | `nip05` field merged from the sidecar after claim |

There is **no NIP-50** fuzzy people search on purpose. Discovery is “type a handle you already know,” not “search the social graph.” The handle points at a pubkey; the chat still opens as a local-first pending conversation and reconciles when background setup finishes — network must not gate first paint.

## Readable group links: HTTPS that still keeps the secret client-side

Custom schemes like `sonar://invite/sinvite1…` are honest but hostile to real sharing: they often do not linkify in iMessage or Signal, they look like noise when forwarded, and people without the app hit a dead end. Sonar follows the Signal shape: a real HTTPS URL that travels well, with the join capability kept out of the server’s request path.

### URL shapes (shipped)

| Form | Shape |
| --- | --- |
| Universal (preferred) | `https://sonarprivacy.xyz/join#sinvite1…` |
| Legacy deep link | `sonar://invite/sinvite1…` |
| Bare token | `sinvite1…` |

The host constant is `sonarprivacy.xyz` in both clients (`InviteShare` on iOS and Compose). Universal Links / App Links association files live under the website’s `.well-known/` so a tap can open the installed app; the static `/join` page still falls back to the custom scheme when needed.

### Why the fragment matters

The invite payload lives in the URL **fragment**. Browsers do not send the fragment to the host on the HTTP request. The landing page’s JavaScript reads `location.hash`, validates a `sinvite1` + hex token, and builds `sonar://invite/…` for the CTA. The website can host the page without ever receiving the capability bytes.

That is the privacy property we wanted for v1: readable and linkifiable, without turning the invite into a server-side lookup by default.

### What is inside `sinvite1…`

The token is a compact encoding of join metadata: group id, group name, **one admin’s npub**, relays, a random invite secret, and a timestamp. The secret is stored hashed on the admin device for validation. Anyone with the link can *request* to join; they do not automatically enter the MLS group.

### End-to-end join path

```
Admin creates link
  → random 32-byte secret, store SHA-256
  → encode sinvite1… token
  → wrap as https://sonarprivacy.xyz/join#token
  → share sheet / QR / copy

Recipient opens or pastes
  → normalize any accepted form → bare sinvite1…
  → publish KeyPackage
  → gift-wrap kind-4445 join request to that admin only

Admin approves
  → MLS add_members + gift-wrapped Welcome
```

Two design choices keep MLS sane:

1. **Single-admin approver in the token** — join requests are gift-wrapped to one admin so concurrent epoch forks from multi-admin races are avoided.
2. **Link ≠ Welcome** — the link is a request credential. Membership still requires admin approval and a real MLS Welcome. That is separate from multi-member Welcomes created when the group was first formed.

Clients accept paste of the universal link, the custom scheme, or the bare token (including when the token is buried in surrounding text). Search and group-info share UI all route through the same normalize → `request_join_via_link` path.

## What we are not claiming

- **A nickname is not a login.** Restoring an account restores the key; the nick hydrates from kind-0 afterward.
- **A handle is not global uniqueness of personality.** It is uniqueness under a domain’s NIP-05 document.
- **A join link is not open membership.** Bearer capability + admin gate; revoke exists in core, product expiry UX is still evolving.
- **Short path aliases** (`https://sonarprivacy.xyz/<code>`) are an optional registrar mapping under active design for SMS/QR length. They trade fragment privacy for a hosted code→token redirect. The shipped default remains the fragment form above.

## Closing

People need names and links. Cryptography needs keys and epochs. Sonar’s job is to keep those layers from collapsing into each other:

- **Nickname** for the room and the chat list.
- **Handle** when you already know who to find.
- **Readable HTTPS invite** when a group should travel through ordinary messengers without leaking the capability to the web host on every open.

The account remains the key. Everything else is how humans point at it.
