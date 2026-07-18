---
title: How Sonar is built — two networks, one conversation, no phone number
cat: Engineering
date: 2026-07-18
summary: Sonar is not "Signal plus Bluetooth." It is one portable Nostr identity driving two transports — Noise over a BLE mesh when you're nearby, MLS (Marmot) over Tor and open relays when you're not — folded into a single conversation without accounts or a central message vault.
author: The Sonar team
read: 12 min read
feature: false
---

# How Sonar is built — two networks, one conversation, no phone number

Most messengers ask you to trust a company, a phone number, and a server farm. Sonar asks you to trust cryptography and an architecture you can read.

This post is the engineering introduction: what the pieces are, how they fit together, and what that means for privacy in practice. It is not a marketing sheet and it is not a substitute for the [technical whitepaper](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/WHITEPAPER.md). It is the map we wish we had when explaining Sonar to another engineer — or to ourselves six months from now.

## The one-sentence model

**Sonar is one portable identity that routes every private conversation over whichever road can reach the other person — Bluetooth when they are nearby, open Nostr relays (through Tor) when they are not — without splitting that person into two chats.**

Everything else in the product is a consequence of that sentence: the bubble colors, the "Nearby · Bluetooth" banners, the mesh-to-internet fold, the Lightning wallet that restores from the same key, the absence of a signup form.

## Why two networks at all

Centralized messengers optimize for one network: the company's. That works until the network is the problem — a cut fiber, a jammed cell tower, a region where using a foreign chat app is itself a risk, or a law that treats the company's servers as a convenient place to insert a scanner.

Sonar inherits a dual-transport design from [bitchat](https://github.com/permissionlesstech/bitchat) and then rebuilds the product around a shared Rust core:

| Road | When it wins | What carries the bits |
| --- | --- | --- |
| **Nearby (BLE mesh)** | Peer in radio range, including offline | Phone-to-phone gossip, Noise-encrypted, multi-hop |
| **Far (Nostr / Marmot)** | Peer out of range, or you never met them in person | MLS group ciphertext over open relays, Tor by default |

The app picks automatically: prefer a live Bluetooth session when one exists, fall back to internet messaging, queue when neither is available. The UI shows which road a given bubble took — cyan for mesh, indigo for internet — the way iMessage distinguishes platforms. Here the color distinguishes *distance*.

That is the product claim. The rest of this post is how it is enforced in code and wire formats.

## Identity: keys, not accounts

Sonar does not issue accounts. There is no phone number, no email, no password reset desk.

A user holds **two cryptographic layers**, generated on device and stored in the platform keychain:

1. **Mesh identity** — a long-term Curve25519 Noise static key (plus an Ed25519 signing key for mesh announcements). Peers are identified by a fingerprint: `SHA256(static public key)`. The short id you sometimes see is the first eight bytes of that fingerprint, hex-encoded. Verification is out-of-band: read a safety number aloud, or scan a QR.
2. **Account identity** — a secp256k1 Nostr keypair, shown as `npub1…` / `nsec1…`. This is the portable Sonar account. The same secret restores profile, Marmot history access, and the Lightning wallet across reinstalls and platforms. Sonar cannot recover a lost `nsec` for you; that is the tradeoff for self-custody.

Sub-identities are derived from the Nostr secret with domain separation — for example, a fresh ephemeral key per geohash channel so public location chat is not trivially linkable to your main `npub`. Call transport keys are similarly derived. The root secret remains the only thing you need to back up.

There is still a social problem every secure messenger has: **how do you know the key belongs to the human in front of you?** Architecture cannot skip that. It can only make the verify step honest (fingerprints and QRs) and refuse to pretend a phone number is identity.

## The mesh road: Noise over Bluetooth

When two Sonar phones are in range, they speak the BitChat BLE mesh protocol. Sessions use the Noise framework pattern **`Noise_XX_25519_ChaChaPoly_SHA256`**: mutual authentication, forward secrecy, and a compact binary framing tuned for BLE MTUs.

Messages can hop across intermediate phones (the product docs describe multi-hop gossip up to seven hops). That is how a room full of devices can keep talking when none of them has cellular data. Mesh DMs live in a **local** message store on your device. There is no Sonar-operated relay holding a copy of those packets. If nobody nearby can forward, the message waits.

Mesh presence is also radio presence. Bluetooth LE advertising is not invisible; a sophisticated RF observer near you can learn that *someone* is running a mesh client. Sonar does not claim to erase physics. It claims that the *contents* of private mesh sessions are Noise-sealed between the parties that completed a handshake — and that there is no central mesh server to subpoena for plaintext.

For the deep Noise walkthrough, see [BRING_THE_NOISE.md](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/BRING_THE_NOISE.md) in the repo.

## The internet road: Tor, relays, and gift wraps

When the other person is not in Bluetooth range, Sonar uses the open Nostr network. Every internet connection is routed through a **local Tor SOCKS5 proxy**, fail-closed in release builds: if Tor is not ready, the client waits rather than falling back to clearnet. Relays therefore see a Tor exit, not your home IP.

Direct messages that are *not* on the Marmot/MLS path use **NIP-17 gift wrapping** (NIP-44 encryption inside a NIP-59 wrap). Relays store and forward ciphertext envelopes; they are not handed the inner sender, recipient, or plaintext of a correctly wrapped DM.

Public **geohash channels** ("around you" rooms addressed by cell precision, not GPS pins shared into the chat) use ephemeral events and per-channel derived keys so presence and chatter in a place are not the same as announcing your main `npub` to the planet. That is a different threat model from private DMs — public rooms are public — and the architecture treats them that way on purpose.

## The flagship private path: Marmot (MLS over Nostr)

Sonar's private and group messaging for internet reach is **Marmot**: IETF **Messaging Layer Security (MLS)** with Nostr as the transport. Sonar pins a specific [MDK](https://github.com/marmot-protocol/mdk) revision so the wire format stays **byte-compatible with [White Noise](https://whitenoise.chat)** in both directions. If someone messages you from White Noise, Sonar should be able to speak the same group ciphertext — and the reverse.

MLS is the reason group membership can change without "everyone shares one static chat key forever." It gives **forward secrecy and post-compromise security** as members and devices join and leave — the same family of properties Signal popularized for 1:1 Double Ratchet chats, applied to groups with a standardized protocol.

On the wire (simplified):

| Purpose | Nostr kind | Notes |
| --- | --- | --- |
| KeyPackage | `30443` (addressable) | Lets others start a group with you |
| Welcome | `444` (gift-wrapped) | Invitation to join an MLS group |
| Group ciphertext | `445` | MLS-encrypted payload; outer event uses an ephemeral signing key |
| Inner chat rumor | `9` | The chat payload carried inside the 445 |

Media (images, files, voice notes) follows the Marmot media path (MIP-04): encrypt, describe with `imeta`, store blobs on **Blossom** servers, fetch with size caps. Relays and blob hosts see ciphertext and metadata bounds, not album plaintext.

### Where history actually lives

This is the sentence people get wrong about "decentralized chat."

**Relays are infrastructure, not your chat database.** They forward and temporarily hold events so devices can catch up. Sonar's MLS state and conversation history for Marmot chats live in a **SQLCipher-encrypted local database**. The 32-byte DB key is owned by the host keychain. Opening a chat paints from that local store first; relay sync is a background updater, not a gate on first paint. That is a deliberate product rule — Signal-shaped local-first performance — not an accident of caching.

So when landing copy says there is no company message vault between you, it means: Sonar does not run a privileged server that can read your DMs. It does **not** mean "zero computers anywhere touch your ciphertext." Open relays and blob servers exist. The privacy bet is cryptographic (MLS, gift wraps, Tor) plus operational (no Sonar-operated account graph), not magic.

## Folding: one person, one conversation

Here is where Sonar stops being "two apps glued together."

You meet someone over Bluetooth. Later they walk out of range. Or you start on White Noise and later stand next to them at a conference. In either order, the product requirement is the same: **do not split one human into two threads.**

The bridge is **Sonar Discovery** — a mesh packet type `0x53` (ASCII `'S'`) advertised alongside the normal BitChat announce. Its TLV payload can carry the peer's 32-byte `npub` and a capabilities bitfield (Marmot DM, payments, …). The packet is signed with the same Ed25519 key as the mesh announce, and receivers only accept it for a sender they already verified. That cryptographically binds "the Bluetooth peer in front of me" to "the Nostr account I can reach later."

Under the hood Sonar therefore has two conversation *kinds*:

- **Pure Marmot** — you only know them as an `npub` / MLS group. Chat id is the group id.
- **Mesh-folded** — you first knew them as a Noise fingerprint (`mesh:…`), and may also have one or more Marmot groups linked through their `npub`.

The UI still shows **one row**. Sends pick a transport per message (`sendDmAuto`: live Noise link → Marmot → NIP-17 → outbox). Unread and transcript code has to respect both kinds; assuming every chat id is an MLS group hex is a recurring class of bugs we document in [`docs/CHAT-TYPES.md`](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/CHAT-TYPES.md).

If you are implementing against Sonar, read that doc before you touch conversation identity. If you are only using the app, the takeaway is simpler: adding White Noise to a mesh contact should feel like the same chat growing a longer-range antenna, not like creating a second contact card.

## What a network observer can learn (honest version)

Good architecture posts state residual risk, not just slogans.

**On the mesh road**, a local RF observer can learn that mesh traffic is happening nearby. Parties that complete a Noise handshake get confidentiality and forward secrecy for that session's contents; phones that only forward multi-hop gossip do not need the plaintext to relay ciphertext.

**On the internet road**, Tor hides your IP from relays. Gift-wrapped DMs hide inner envelope fields from relays that only see the wrap. MLS `445` events are ciphertext; group membership metadata and timing are still a research-grade concern in any MLS-over-public-transport design — Sonar inherits that industry problem rather than claiming to have invented a metaphysical fix. Geohash public channels are public by design.

**On the device**, a stolen unlocked phone with a compromised keychain is game over for local state, as with any E2EE messenger. Remote wipe and "trust us, we deleted it" are not the model; export and custody of the `nsec` are.

**What Sonar is designed not to create:** a Sonar-operated social graph of phone numbers, a privileged plaintext archive, or a closed client binary where a scanning module could ship without the source changing in public.

## Money on the same roads (briefly)

Sonar can carry value the way it carries messages. An optional Lightning wallet (Breez SDK Liquid) derives from the same account secret, so restoring an `nsec` restores the wallet. Nearby payments can move over BLE without requiring a full chat session. Bitcoin mode is off by default on the landing narrative for a reason: messaging privacy should not depend on enabling payments.

Payments have their own threat model (amounts, BIP-353 addresses, Lightning metadata). Treat them as a related subsystem, not as proof that DMs are private. Specs live under [`docs/SONAR-PAYMENTS.md`](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-PAYMENTS.md).

## One core, many shells

Implementation shape matters for auditability.

Sonar is **one headless Rust core** (`core/sonar-core`) compiled into:

- native SwiftUI apps (iOS / macOS)
- Compose Multiplatform (Android today; desktop catching up on mesh and wallet)

The core owns identity, Marmot, geohash, mesh orchestration, and call signaling. Platforms own radios, keychain, notifications, and UI. UniFFI bindings are generated at build time. That is why "fix it in the core" is the default answer for cross-platform conversation bugs — and why platform gaps (for example desktop BLE messaging still maturing) are tracked explicitly rather than papered over in marketing.

## How to verify us

Sonar is released into the public domain (see `LICENSE`). The interesting verification steps are not license badges:

1. **Read the protocols** — [WHITEPAPER.md](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/WHITEPAPER.md), [BRING_THE_NOISE.md](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/BRING_THE_NOISE.md), [`docs/`](https://github.com/hedwig-corp/bitchat-to-sonar/tree/main/docs).
2. **Diff the client** — especially send paths, Tor fail-closed behavior, and anything that touches key material.
3. **Confirm White Noise interop** at the MDK pin — wire compatibility is a testable claim, not a vibe.
4. **Verify people** with safety numbers / QR, the way you would with any E2EE app.

What we are *not* claiming in this post: a completed third-party audit of the whole stack, perfect metadata anonymity, or that every platform surface (desktop mesh messaging, desktop wallet, calls maturity) is equally finished. Incomplete surfaces are called out in the README platform table on purpose.

## Closing

Sonar exists because private messaging that only works when a company's servers say so is brittle — against outages, against borders, and against laws that treat intermediaries as convenient control points.

The architecture bet is narrow and concrete:

- **Noise** for the room you are standing in.
- **MLS (Marmot) over Tor and Nostr** for the people who are not.
- **One `npub`**, folded with a mesh fingerprint, so a person stays a person.
- **Local encrypted history first**, relays as catch-up, not as the source of truth you wait on to open a chat.

If that matches how you think software should treat speech, the code is public and the apps are on the [download page](Sonar%20Landing.html). If you want the longer formal treatment, start with the [whitepaper](https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/WHITEPAPER.md) and the [in-site docs](Sonar%20Docs.html).

---

*Sonar is free and open source. [Read the docs](Sonar%20Docs.html) or [get the app](Sonar%20Landing.html).*
