# Sonar Discovery — npub + payment address over the BLE mesh

**Status:** v1 (packet version 1), implemented in the Sonar iOS app.
**Wire type:** BitchatPacket raw type `0x53` (`'S'`).

## Motivation

bitchat's BLE mesh tells you *who is nearby* (announce, type `0x01`) but not
*how to reach them off-mesh*. Sonar peers additionally carry:

1. a persistent **Nostr identity** (npub) usable for **Marmot** (MLS over
   Nostr) secure chats — so anyone nearby running Sonar or
   [White Noise](https://whitenoise.chat) can message them over the internet
   after walking away, and
2. an optional **BIP-353 payment address** (`user@domain`) for the upcoming
   bitcoin payments milestone.

Sonar Discovery broadcasts exactly this, alongside — never instead of — the
untouched bitchat announce.

## Compatibility statement

`0x53` is **not** added to bitchat's `MessageType` enum. Stock bitchat
clients hit their unknown-type branch (`BLEService.handleReceivedPacket`,
`case .none:` → "Unknown message type"), ignore the payload, and still relay
the packet by TTL like any other broadcast. The bitchat mesh is unaffected by
design; no existing packet, field, or state machine is modified.

`0x53` is hereby reserved for Sonar Discovery. Future Sonar mesh extensions
must pick other unused type bytes and follow the same "unknown types are
ignored + relayed" rule.

## Packet

Standard `BitchatPacket` framing (13-byte header, version 1) — see
`WHITEPAPER.md`:

| Field       | Value                                                        |
|-------------|--------------------------------------------------------------|
| version     | 1                                                            |
| type        | `0x53`                                                       |
| ttl         | same as the announce (`TransportConfig.messageTTLDefault`)   |
| senderID    | sender's 8-byte routing ID (same as its announce)            |
| recipientID | broadcast (absent / `0xFF…FF`)                               |
| timestamp   | u64 milliseconds since epoch                                 |
| payload     | TLV body (below)                                             |
| signature   | Ed25519, REQUIRED (same scheme + key as the announce)        |

A Sonar announce SHOULD be sent immediately after every bitchat announce
(initial, periodic, announce-back), subject to the same throttling.

## Payload TLV

Same TLV encoding as `AnnouncementPacket` (`bitchat/Protocols/Packets.swift`):
1 type byte, 1 length byte (u8), `length` value bytes, repeated.

| TLV    | Name         | Size      | Req. | Meaning                                          |
|--------|--------------|-----------|------|--------------------------------------------------|
| `0x01` | version      | 1 (u8)    | yes  | payload version; this document defines `1`       |
| `0x02` | npub         | 32 bytes  | yes  | raw x-only Nostr public key (the bech32 `npub` decoded) |
| `0x03` | bip353       | ≤255 B    | no   | UTF-8 BIP-353 address `user@domain`, **no leading ₿** |
| `0x04` | capabilities | 1 (u8)    | yes  | bitfield, see below                              |

Capabilities bitfield:

| Bit | Mask   | Name      | Meaning                                              |
|-----|--------|-----------|------------------------------------------------------|
| 0   | `0b01` | marmot-dm | the npub accepts Marmot DMs (KeyPackage published)   |
| 1   | `0b10` | payments  | the peer speaks the ⚡PAY payment convention (see `SONAR-PAYMENTS.md`); a BIP-353 address MAY additionally be advertised via TLV `0x03` |

Current senders set `0b11`. Unknown bits MUST be ignored.

### Forward compatibility rules

- Receivers MUST skip TLV types they don't know and keep parsing.
- Receivers MUST reject the payload when: the version TLV is missing or has a
  value other than a version they understand; the npub TLV is missing or not
  exactly 32 bytes; the capabilities TLV is missing; or any TLV length
  overruns the payload.
- Senders MUST NOT rely on receivers understanding any TLV other than the
  four above; new optional TLVs may be added without a version bump, new
  required semantics need a new version value.

## Signature — binding to the bitchat announce identity

The packet is signed with the **same Ed25519 signing key** that signs the
sender's bitchat announce, using the same canonical bytes
(`BitchatPacket.toBinaryDataForSigning()`: signature omitted, TTL zeroed).

Receivers MUST:

1. only accept a Sonar announce for a `senderID` they have already accepted a
   **verified** bitchat announce from (bitchat requires verified announces to
   create a peer), and
2. verify the `0x53` signature against that peer's known
   `signingPublicKey` from its announce.

This binds the advertised npub/payment address to the exact identity already
proven on the mesh — a relaying node cannot substitute its own npub without
failing verification. Stale packets older than the announce window (15
minutes) are dropped. Unsigned or unverifiable packets MUST be dropped
silently.

Note the binding is to the *mesh* (Noise/Ed25519) identity; there is no
proof of npub ownership beyond the announcer's claim. Treat the npub with
the same trust as the peer's nickname until verified out-of-band (QR /
safety numbers / Marmot session).

## Interaction with White Noise (Marmot)

Given a discovered npub, a client can start a secure internet chat per the
[Marmot protocol](https://github.com/marmot-protocol/marmot):

1. fetch the peer's **MIP-00 KeyPackage** (kind `30443`) from relays (their
   kind `10051` relay list, falling back to defaults),
2. create the MLS group and send the **Welcome** (kind `444` inside a NIP-59
   gift wrap `1059`),
3. exchange group messages (kind `445`).

This is exactly what White Noise speaks, so a Sonar user discovered over BLE
can be messaged from White Noise (and vice versa) with no further exchange —
the radar becomes a contact-exchange surface. In the Sonar app this is
`MarmotChatModel.startChat(with: npub)`.

The sender advertises the npub of its Marmot identity (keychain `marmot-nsec`),
i.e. the identity whose KeyPackages it publishes.

## BIP-353 payment address

The optional TLV `0x03` carries a
[BIP-353](https://github.com/bitcoin/bips/blob/master/bip-0353.mediawiki)
human-readable address `user@domain` (stored/transmitted without the display
prefix `₿`). Payers resolve it via DNSSEC-secured TXT records
(`user.user._bitcoin-payment.domain`) into a BIP-21 URI — typically a
reusable bolt12 offer or silent-payment address.

v1 only *advertises* the address (payments milestone lands later). Clients
showing it SHOULD render it as `₿user@domain` and MUST treat it as untrusted
input (it inherits only the mesh-identity binding above; DNSSEC verification
happens at payment time).

## Reference implementation

- Payload codec + constants: `bitchat/Protocols/SonarDiscovery.swift`
- Send/receive + verification: `bitchat/Services/BLE/BLEService.swift`
  (`sendSonarAnnounce`, `handleSonarAnnounce`)
- App store / UI: `bitchat/Views/Sonar/SonarAppStore.swift` (profiles map,
  BIP-353 setting, provider injection), radar badge + secure-chat offer in
  `SonarRadarScreen.swift`, payment-address field in `SonarProfileScreen.swift`
- Tests: `bitchatTests/Protocols/SonarDiscoveryTests.swift`
