# Sonar Discovery

Sonar discovery has two complementary paths:

1. **BLE proximity discovery**: a Sonar-specific `BitchatPacket` raw type
   `0x53` is broadcast over the existing bitchat BLE mesh. This works offline
   and is preferred whenever the peer is in range.
2. **Nostr npub discovery**: a public, npub-signed Sonar descriptor is stored
   as a Nostr app-data event. This is the online fallback for peers that are no
   longer in BLE range but whose npub is known.

The decision history started in
[`/brainstorm capabilities on White Noise accounts`](brainstorms/2026-06-16-capabilities-on-whitenoise-accounts.md).
The final implementation changed one important detail from that brainstorm:
Sonar does **not** publish live Iroh node addresses in a Nostr profile. It
publishes only stable capability and protocol-route metadata in a separate
descriptor. Live call addresses stay inside encrypted call offer/answer
messages.

## Discovery Decision

Sonar treats an `npub` as the durable account identity. A user with an npub can
be contacted over Marmot/White Noise text messaging if their Marmot KeyPackage
exists on relays. Extra Sonar capabilities, such as voice/video calls, must be
discovered separately.

The call-discovery rule is:

- If BLE is reachable, prefer the BLE `0x53` profile and live mesh route.
- If BLE is not reachable and the app is online, fetch the public Sonar
  descriptor for the peer's npub.
- If the descriptor exists and advertises a compatible call route, the peer is
  a Sonar call-capable user.
- If the descriptor is missing, malformed, or incompatible, keep the peer as a
  White Noise/Marmot contact but do not show or accept Sonar call affordances.

This keeps local/offline behavior fast while still allowing account-level call
discovery after the users are no longer nearby.

## Privacy Model

The two discovery paths have different visibility:

| Path | Visibility | What it exposes | What it does not expose |
| --- | --- | --- | --- |
| BLE `0x53` | Nearby mesh participants that receive or relay the packet while TTL is alive | npub, optional BIP-353 address, capability bits | nsec, live Iroh addresses, call IDs |
| Nostr descriptor | Public to anyone who can query the user's relays and knows or discovers the npub | Sonar app marker, call/media support, compatible signaling and transport names | nsec, live Iroh addresses, IP addresses, call IDs, presence, accept/decline state |

The Nostr descriptor is public by design. It is signed by the same Nostr account
key represented by the npub, so it proves "this npub published these Sonar
capabilities"; it does not prove that a particular BLE device is the same user.
The BLE path separately binds the npub claim to the verified mesh identity via
the `0x53` packet signature.

## BLE Proximity Discovery

**Status:** packet version 1, implemented by the Sonar app surfaces that support
the bitchat mesh.

**Wire type:** `BitchatPacket` raw type `0x53` (`'S'`).

bitchat's normal BLE announce tells the app who is nearby, but not how to reach
that peer off-mesh. Sonar broadcasts a second packet after the normal announce
with:

1. the peer's Marmot/Nostr identity (`npub`),
2. an optional BIP-353 payment address (`user@domain`), and
3. a capability bitfield.

The normal bitchat announce remains untouched. `0x53` is deliberately not added
to bitchat's `MessageType` enum; stock bitchat clients hit the unknown-type
branch, ignore the payload, and continue relaying by TTL.

### BLE Packet

Standard `BitchatPacket` framing, version 1:

| Field | Value |
| --- | --- |
| version | `1` |
| type | `0x53` |
| ttl | same as the announce (`TransportConfig.messageTTLDefault`) |
| senderID | sender's 8-byte routing ID |
| recipientID | broadcast, absent, or `0xFF...FF` |
| timestamp | u64 milliseconds since epoch |
| payload | TLV body |
| signature | Ed25519, required |

A Sonar announce should be sent immediately after every bitchat announce
initial, periodic, and announce-back path, subject to the same throttling.

### BLE Payload TLV

The payload uses the same TLV shape as `AnnouncementPacket`: one type byte, one
u8 length byte, then `length` value bytes.

| TLV | Name | Size | Required | Meaning |
| --- | --- | --- | --- | --- |
| `0x01` | version | 1 byte | yes | payload version; this document defines `1` |
| `0x02` | npub | 32 bytes | yes | raw x-only Nostr public key |
| `0x03` | bip353 | <=255 bytes | no | UTF-8 BIP-353 address, no leading display prefix |
| `0x04` | capabilities | 1 byte | yes | bitfield |

Capability bits:

| Bit | Mask | Name | Meaning |
| --- | --- | --- | --- |
| 0 | `0b0000_0001` | `marmot-dm` | the npub accepts Marmot DMs |
| 1 | `0b0000_0010` | `payments` | the peer speaks the Sonar payment convention; BIP-353 may also be present |
| 2 | `0b0000_0100` | `calls` | the peer supports Sonar voice/video calls |

Current senders advertise Marmot DMs and calls. They advertise payments only
when the wallet is configured to receive.

### BLE Validation

Receivers must:

- skip unknown TLV types and keep parsing,
- reject unknown versions,
- reject a missing or non-32-byte npub,
- reject a missing capabilities TLV,
- reject TLV lengths that overrun the payload,
- only accept a Sonar announce for a sender with an already verified bitchat
  announce, and
- verify the `0x53` signature against the sender's mesh announce signing key.

That signature binds the advertised npub and payment/call capability bits to
the verified mesh identity. A relay node cannot substitute its own npub without
failing verification.

## Nostr Npub Descriptor Discovery

The online fallback uses a Nostr application-data descriptor based on
[NIP-78](https://nips.nostr.com/78). NIP-78 defines kind `30078` as an
addressable custom app-data event with a `d` tag that identifies the app-specific
record. Sonar uses that shape for a public call-capability manifest.

Sonar descriptor constants:

| Field | Value |
| --- | --- |
| kind | `30078` |
| `d` tag | `sonar.call.v1` |
| app marker | `sonar` |
| schema | `1` |
| default signaling route | `marmot` |
| default transport | `iroh` |
| call identity | `iroh-hkdf-sonar-call-iroh-v1` |

Example descriptor content:

```json
{
  "schema": 1,
  "app": "sonar",
  "calls": true,
  "media": ["voice", "video"],
  "signaling": ["marmot"],
  "transports": ["iroh"],
  "call_identity": "iroh-hkdf-sonar-call-iroh-v1"
}
```

The descriptor is intentionally small and stable. It tells a peer that this npub
is a Sonar client with compatible call protocol support. It does not contain
session-specific reachability data.

### Descriptor Publishing

The Rust core publishes the descriptor with:

- `SONAR_DESCRIPTOR_KIND = 30078`
- `SONAR_DESCRIPTOR_D_TAG = "sonar.call.v1"`
- a `#sonar` hashtag
- JSON content generated by the current schema
- the user's Nostr signing key

On Apple clients, `MarmotChatModel.performConnect()`:

1. loads or generates the identity so the npub can be used offline by BLE,
2. connects the Marmot/Nostr node,
3. loads local chats,
4. refreshes from relays,
5. publishes the Marmot KeyPackage, and
6. publishes the Sonar descriptor.

Older clients, relay failures, or users who have never connected may not have a
descriptor yet.

### Descriptor Fetching

The Rust core fetches descriptors with a Nostr filter:

- `kind = 30078`
- `author = peer npub`
- `#d = sonar.call.v1`
- `limit = 5`

It sorts by newest timestamp and accepts the first event that:

- was authored by the requested npub,
- has the required `d` tag,
- has content no larger than 4096 bytes,
- parses as schema `1`,
- has `app = "sonar"`, and
- contains normalized protocol tokens.

Invalid or incompatible descriptors are ignored. A missing descriptor means "not
confirmed as Sonar call-capable"; it does not mean the npub is invalid.

### Descriptor Caching

Apple clients cache descriptor lookups in `MarmotChatModel`:

- positive descriptors refresh after 15 minutes,
- relay misses retry after 60 seconds,
- in-flight fetches are deduplicated per npub,
- transient relay/network errors leave the last known descriptor in place, and
- successful `nil` lookups remove stale positive descriptors and record a miss.

Fetches are triggered when:

- local Marmot groups are loaded,
- relay refresh reloads local group state,
- a secure chat starts from an npub,
- a call affordance checks `canCall`, or
- an incoming call offer needs descriptor confirmation.

The app does not query relays on every render.

## Call Gating

For Apple clients, `SonarAppStore.canCall(_:)` allows voice/video calls when the
conversation has a signaling route and either:

1. the BLE Sonar profile has the `calls` capability bit, or
2. the fetched Nostr descriptor has `calls = true`, includes `marmot` signaling,
   includes `iroh` transport, and uses
   `iroh-hkdf-sonar-call-iroh-v1`.

Incoming Marmot call offers are deferred while descriptor discovery is in flight
for an otherwise unknown npub. If the descriptor fetch confirms Sonar call
support, the offer can proceed. If the fetch misses, the offer is ignored rather
than accepting a Sonar-only call from an unconfirmed White Noise account.

## Platform Status

| Surface | BLE `0x53` | Nostr descriptor publish/fetch | Call gating from descriptor |
| --- | --- | --- | --- |
| Rust core | packet-independent; descriptor APIs live in `sonar-core` | yes | provides parsed descriptor only |
| UniFFI | exposes descriptor APIs to Swift and generated Kotlin bindings | yes | app-layer responsibility |
| iOS | yes | yes | yes |
| macOS | yes, through shared Apple app code | yes | yes |
| Compose Android/Desktop | yes, using BLE/persisted capability state | FFI APIs are generated | not wired in app state yet |
| Web | no local mesh runtime | no Marmot/Sonar runtime descriptor client | no |

Before claiming account-level npub call discovery on Compose, wire the generated
`fetchSonarDescriptor` API into the shared app state and mirror the Apple cache
semantics.

## Reference Implementation

- BLE payload codec and constants:
  `ios/bitchat/Protocols/SonarDiscovery.swift`
- BLE send/receive and verification:
  `ios/bitchat/Services/BLE/BLEService.swift`
- Rust descriptor codec:
  `core/sonar-core/src/sonar_descriptor.rs`
- Rust descriptor publish/fetch:
  `core/sonar-core/src/client.rs`
- UniFFI descriptor bridge:
  `core/sonar-ffi/src/lib.rs`
- Apple Marmot service wrapper:
  `ios/bitchat/Services/MarmotService.swift`
- Apple descriptor cache and refresh:
  `ios/bitchat/Views/MarmotChatView.swift`
- Apple call gating:
  `ios/bitchat/Views/Sonar/SonarAppStore.swift`
- Compose BLE call gating:
  `apps/sonar/composeApp/src/commonMain/kotlin/chat/bitchat/sonar/SonarAppState.kt`

Related docs:

- [Sonar payments](SONAR-PAYMENTS.md)
- [Marmot persistence](MARMOT-PERSISTENCE.md)
- [NIP-78 application data](https://nips.nostr.com/78)
