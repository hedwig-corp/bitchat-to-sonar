// Sonar documentation content — ported 1:1 from the Claude Design handoff:
//   design/handoff/project/sonar/docs-content.js
// Keep this file in lockstep with that source; do not edit the prose here.
/**
 * @typedef {{ title: string, gh: string, md: string, blurb?: string, status?: string, kind?: string }} SonarDoc
 * @type {{ groups: { name: string, items: string[] }[], docs: Record<string, SonarDoc> }}
 */
export const SONAR_DOCS = {
  groups: [
    { name: 'Overview', items: ['index'] },
    { name: 'Protocol', items: ['SONAR-DISCOVERY', 'SONAR-NOTIFICATIONS'] },
    { name: 'Money', items: ['SONAR-PAYMENTS', 'bip353-registration'] },
    { name: 'Content', items: ['SONAR-STICKERS'] },
  ],
  docs: {
    index: {
      title: 'Introduction',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/tree/main/docs',
      blurb: 'what sonar is and how these docs are organized',
      md: `# Sonar documentation

Sonar is a private, offline-capable messenger. It finds people over a **Bluetooth mesh** when they are nearby and reaches anyone else over the **open Nostr network** — with no phone number, no account, and no servers.

These docs describe the protocols and conventions behind the app.

## Where to start

- **[Discovery](SONAR-DISCOVERY.md)** — how peers find each other over BLE and Nostr, and how capabilities are advertised.
- **[Notifications](SONAR-NOTIFICATIONS.md)** — the core-owned notification envelope and push delivery.
- **[Payments](SONAR-PAYMENTS.md)** — direct Bolt12 wallet payments and the in-chat receipt format.
- **[Stickers](SONAR-STICKERS.md)** — the open sticker-pack directory published on Nostr.

## Principles

1. **Local first.** Anything that can work offline, works offline. Online paths are fallbacks, not requirements.
2. **The npub is the identity.** A durable Nostr public key is the account; everything else is discovered from it.
3. **Publish capability, never presence.** Descriptors say what a peer *can* do, never where they are or whether they are online.
4. **No new identifiers.** Sonar rides existing bitchat mesh framing and standard Nostr event kinds.

> These pages are generated from the \`docs/\` folder of the repository. Use **View on GitHub** on any page to read the source.`,
    },

    'SONAR-DISCOVERY': {
      title: 'Discovery',
      status: 'packet v1',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-DISCOVERY.md',
      blurb: 'ble 0x53 and nostr descriptor peer discovery capabilities',
      md: `# Sonar Discovery

Sonar discovery has two complementary paths:

1. **BLE proximity discovery**: a Sonar-specific \`BitchatPacket\` raw type \`0x53\` is broadcast over the existing bitchat BLE mesh. This works offline and is preferred whenever the peer is in range.
2. **Nostr npub discovery**: a public, npub-signed Sonar descriptor is stored as a Nostr app-data event. This is the online fallback for peers that are no longer in BLE range but whose npub is known.

Sonar does **not** publish live Iroh node addresses in a Nostr profile. It publishes only stable capability and protocol-route metadata in a separate descriptor. Live call addresses stay inside encrypted call offer/answer messages.

## Discovery decision

Sonar treats an \`npub\` as the durable account identity. A user with an npub can be contacted over Marmot/White Noise text messaging if their Marmot KeyPackage exists on relays. Extra Sonar capabilities, such as voice/video calls, must be discovered separately.

The call-discovery rule is:

- If BLE is reachable, prefer the BLE \`0x53\` profile and live mesh route.
- If BLE is not reachable and the app is online, fetch the public Sonar descriptor for the peer's npub.
- If the descriptor exists and advertises a compatible call route, the peer is a Sonar call-capable user.
- If the descriptor is missing, malformed, or incompatible, keep the peer as a White Noise/Marmot contact but do not show or accept Sonar call affordances.

This keeps local/offline behavior fast while still allowing account-level call discovery after the users are no longer nearby.

## Privacy model

The two discovery paths have different visibility:

| Path | Visibility | What it exposes | What it does not expose |
| --- | --- | --- | --- |
| BLE 0x53 | Nearby mesh participants while TTL is alive | npub, optional BIP-353 address, capability bits | nsec, live Iroh addresses, call IDs |
| Nostr descriptor | Public to anyone who can query the user's relays and knows the npub | Sonar app marker, call/media support, signaling and transport names | nsec, live addresses, IPs, call IDs, presence |

The Nostr descriptor is public by design. It is signed by the same account key represented by the npub, so it proves "this npub published these Sonar capabilities". The BLE path separately binds the npub claim to the verified mesh identity via the \`0x53\` packet signature.

## BLE proximity discovery

**Wire type:** \`BitchatPacket\` raw type \`0x53\` (\`'S'\`). bitchat's normal announce tells the app who is nearby, but not how to reach that peer off-mesh. Sonar broadcasts a second packet after the normal announce with the peer's identity, an optional payment address, and a capability bitfield.

\`0x53\` is deliberately not added to bitchat's \`MessageType\` enum; stock bitchat clients hit the unknown-type branch, ignore the payload, and continue relaying by TTL.

### Payload TLV

The payload uses one type byte, one u8 length byte, then \`length\` value bytes.

| TLV | Name | Size | Required | Meaning |
| --- | --- | --- | --- | --- |
| 0x01 | version | 1 byte | yes | payload version (1) |
| 0x02 | npub | 32 bytes | yes | raw x-only Nostr public key |
| 0x03 | bip353 | <=255 bytes | no | UTF-8 BIP-353 address |
| 0x04 | capabilities | 1 byte | yes | bitfield |

Capability bits:

| Bit | Mask | Name | Meaning |
| --- | --- | --- | --- |
| 0 | 0b0000_0001 | marmot-dm | the npub accepts Marmot DMs |
| 1 | 0b0000_0010 | payments | the peer speaks the Sonar payment convention |
| 2 | 0b0000_0100 | calls | the peer supports Sonar voice/video calls |

Current senders advertise Marmot DMs and calls. They advertise payments only when the wallet is configured to receive.

### Validation

Receivers must skip unknown TLV types, reject unknown versions, reject a missing or non-32-byte npub, reject a missing capabilities TLV, only accept a Sonar announce for an already-verified bitchat announce, and verify the \`0x53\` signature against the sender's mesh announce signing key. That signature binds the advertised npub and capability bits to the verified mesh identity — a relay node cannot substitute its own npub without failing verification.

## Nostr descriptor discovery

The online fallback uses a Nostr application-data descriptor based on NIP-78, which defines kind \`30078\` as an addressable app-data event with a \`d\` tag.

| Field | Value |
| --- | --- |
| kind | 30078 |
| d tag | sonar.call.v1 |
| app marker | sonar |
| schema | 1 |
| default signaling | marmot |
| default transport | iroh |

Example descriptor content:

\`\`\`json
{
  "schema": 1,
  "app": "sonar",
  "calls": true,
  "media": ["voice", "video"],
  "signaling": ["marmot"],
  "transports": ["iroh"],
  "call_identity": "iroh-hkdf-sonar-call-iroh-v1"
}
\`\`\`

The descriptor tells a peer that this npub is a Sonar client with compatible call support. It does not contain session-specific reachability data. A missing descriptor means "not confirmed as Sonar call-capable" — it does not mean the npub is invalid.

## Call gating

Voice/video calls are allowed when the conversation has a signaling route and either the BLE Sonar profile has the \`calls\` bit, or the fetched descriptor has \`calls = true\` with \`marmot\` signaling and \`iroh\` transport. Incoming call offers are deferred while descriptor discovery is in flight for an otherwise unknown npub.`,
    },

    'SONAR-NOTIFICATIONS': {
      title: 'Notifications',
      status: 'v1',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-NOTIFICATIONS.md',
      blurb: 'core-owned notification envelope push delivery muting',
      md: `# Sonar Notifications

Notifications are owned by the Rust core, not by each platform. The core builds a single **notification envelope** and every surface — iOS, Android, desktop — renders the same envelope so copy and behavior stay identical.

## The envelope

The core emits a normalized envelope for every notifiable event:

\`\`\`json
{
  "kind": "dm" | "group" | "call" | "payment" | "join-request",
  "conversationId": "…",
  "title": "Maya",
  "body": "find me by the coffee table",
  "sender": { "npub": "npub1…", "supporter": true },
  "muteRespected": true
}
\`\`\`

The platform layer maps \`kind\` to a channel and renders the title/body verbatim. It never composes notification copy itself.

## Privacy-preserving previews

Users choose how much shows on the lock screen:

| Setting | Title | Body |
| --- | --- | --- |
| Show names & preview | sender name | message text |
| Show names only | sender name | "New message" |
| Hide everything | "Sonar" | "New message" |

The core applies the setting **before** the envelope leaves the process, so a hidden preview never reaches the OS notification system as plaintext.

## Muting

Muting is per-conversation and time-boxed. A muted conversation still receives and decrypts messages; it simply suppresses the envelope.

| Duration | Behavior |
| --- | --- |
| 1 hour / 8 hours | temporary, auto-expires |
| 1 week | temporary, auto-expires |
| Until I turn it back on | indefinite |

A muted conversation shows a small muted glyph in the list. Mentions in a muted group may still notify, depending on the user's mention setting.

## Delivery paths

- **Foreground / nearby:** delivered directly from the mesh or an open relay subscription; no push service involved.
- **Background:** an encrypted push envelope wakes the app, which fetches and decrypts the real message. The push service never sees plaintext.

See the platform integration notes for the iOS NSE and Android FCM paths.`,
    },

    'SONAR-PAYMENTS': {
      title: 'Payments',
      status: 'v2 draft',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-PAYMENTS.md',
      blurb: 'direct bolt12 wallet payments in-chat receipts gold',
      md: `# Sonar Payments

New Sonar clients do not create claimable chat coins when sending money. The receiver publishes public payment metadata in their Sonar descriptor, and the sender pays that wallet destination **directly**.

## Current send path: direct wallet payment

The app publishes two addressable kind \`30078\` descriptor events during migration:

- \`d=sonar.call.v1\`: old call-only schema for old clients.
- \`d=sonar.meta.v1\`: unified Sonar metadata — the preferred schema, carrying direct payment receive metadata.

The payment part of \`sonar.meta.v1\`:

\`\`\`json
{
  "schema": 2,
  "app": "sonar",
  "payments": {
    "receive": [
      {
        "type": "bolt12_offer",
        "offer": "lno1...",
        "network": "bitcoin",
        "proofs": ["preimage"],
        "future_proofs": ["bolt12_payer_proof"]
      }
    ],
    "receipts": ["sonar.payment.receipt.v1"]
  }
}
\`\`\`

Send flow:

\`\`\`text
sender                                receiver
------                                --------
fetch sonar.meta.v1
read payments.receive[bolt12_offer]
record activity: pending
wallet.send(offer, sats) -> preimage
record activity: paid/failed
PAY|1|uuid|sats  ------------------>  record incoming receipt: pending
PAYDONE|2|uuid|preimage  ---------->  mark receipt paid + store preimage
\`\`\`

Direct sends require a valid BOLT12 offer from the peer's Sonar metadata. BLE payment capability bits may show the affordance while the descriptor is being fetched, but sending refuses until the concrete offer is available.

## Chat UX

Money still appears inside the chat. A direct send pays the receiver's wallet, then posts **gold payment receipt bubbles** using the encrypted chat transport. There is no "tap to claim" step for these bubbles.

The wallet sheet lists direct payment activity, newest first: Sonar direct sends, Unify nearby sends to Bluetooth-discovered wallets, and generic incoming wallet payments — with status, amount, peer name, rail, and fee.

## Chat receipt wire format

\`\`\`text
PAY|1|uuid|sats               payment receipt (sender -> receiver)
PAYDONE|2|uuid                settled receipt, no preimage available
PAYDONE|2|uuid|preimage_hex   settled receipt with cryptographic proof
\`\`\`

\`preimage_hex\` is the 32-byte Lightning preimage (64 hex chars). Receivers verify settlement by checking \`SHA256(preimage) == payment_hash\`.

\`PAY\` is a receipt, not a Bitcoin claim primitive. \`PAYDONE\` can race ahead of \`PAY\` on relay-backed transports; clients remember the DONE and mark the matching receipt paid once \`PAY\` arrives. Unknown versions render as plain text.

## Missing offer behavior

When a peer has no direct receive offer, calls can still use \`sonar.call.v1\`, but "Send money" is hidden because there is no destination to pay. This avoids presenting a claimable UX for a payment that now settles directly.`,
    },

    'bip353-registration': {
      title: 'BIP-353 addresses',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/bip353-registration.md',
      blurb: 'human readable payment address user domain dns',
      md: `# BIP-353 payment addresses

BIP-353 lets a user hand out a human-readable payment address like \`maya@sonar.app\` instead of a raw Bolt12 offer. Under the hood it resolves to the same offer via a signed DNS record.

## Why Sonar uses it

- A name is easy to say out loud, print, or verify in person.
- The underlying offer can rotate without the user reprinting anything.
- It composes with discovery: the address travels in the BLE \`0x53\` payload and the Nostr descriptor, so nearby and remote peers resolve the same name.

## Resolution

\`\`\`text
maya@sonar.app
   -> DNS TXT at maya.user._bitcoin-payment.sonar.app
   -> bitcoin:?lno=lno1...   (a Bolt12 offer)
   -> wallet.send(offer, sats)
\`\`\`

The client validates the DNSSEC chain before trusting the record. An address that fails validation is treated as "no offer" — the send affordance stays hidden rather than paying an unverified destination.

## In the UI

A resolved address shows on the contact profile under the payment capability, in monospace. The raw offer is never shown as the primary label — the name is the identity, the offer is plumbing.`,
    },

    'SONAR-STICKERS': {
      title: 'Stickers',
      status: 'ship plan',
      kind: 'kind:30030',
      gh: 'https://github.com/hedwig-corp/bitchat-to-sonar/blob/main/docs/SONAR-STICKERS.md',
      blurb: 'sticker packs published on nostr open directory',
      md: `# Sonar Stickers

Sticker packs are published to the open Nostr network as addressable events. There is no store and no gatekeeper: anyone can publish a pack, and any client — or the web directory — can discover it.

## Event model

| Event | Kind | Meaning |
| --- | --- | --- |
| Pack | 30030 | an addressable sticker pack authored by an npub |
| Installed list | 10030 | a user's list of installed packs |

A pack event carries the pack title, author, tags, and an ordered list of sticker references. Each sticker is content-addressed, so a pack cannot be silently altered after you install it.

## Discovery

The [web directory](Sonar%20Stickers.html) indexes public pack events and lets anyone browse, search by tag, and preview a pack before adding it. Because packs are plain Nostr events, the directory is a convenience, not an authority — clients can mirror or replace it.

\`\`\`text
author signs pack (kind 30030)
   -> relays
   -> directory indexes #t tags + title
   -> user taps "Add to Sonar"
   -> client appends to installed list (kind 10030)
\`\`\`

## Ownership

A pack is owned by the npub that signed it, forever. "Verified maker" in the directory means the pack's author key matches a known identity — it does not gate publishing. There is no review queue and no fee.

## In-app picker

The composer sticker picker reads the user's installed list (kind 10030), resolves each pack, and renders recents first. Sending a sticker posts a bubble-less media message so the art is the message — the timestamp and delivery state sit beneath it.`,
    },
  },
};
