//
// SonarDiscovery.swift
// bitchat
//
// Sonar discovery standard (spec: docs/SONAR-DISCOVERY.md).
//
// Alongside bitchat's untouched announce (0x01), Sonar peers broadcast a
// second mesh packet with raw type 0x53 carrying their Nostr identity
// (x-only pubkey, npub) so nearby people can message them on White Noise /
// Marmot, plus an optional BIP-353 payment address (user@domain) for the
// upcoming bitcoin payments support.
//
// Wire compatibility: 0x53 is deliberately NOT a MessageType case — stock
// bitchat clients hit their `case .none` branch, log "Unknown message type"
// and relay/ignore the packet, so the bitchat mesh is unaffected.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Capability bitfield bits carried in the Sonar announce (TLV 0x04).
enum SonarCapability {
    /// The announced npub accepts Marmot (MLS-over-Nostr) DMs — White Noise interop.
    static let marmotDM: UInt8 = 0b0000_0001
    /// The peer speaks the ⚡PAY payment convention (docs/SONAR-PAYMENTS.md);
    /// a BIP-353 payment address MAY additionally be advertised (TLV 0x03).
    static let payments: UInt8 = 0b0000_0010
    /// The peer supports Sonar voice/video calls — a Sonar-only feature.
    static let calls: UInt8 = 0b0000_0100
}

/// Payload of the Sonar discovery announce (BitchatPacket raw type 0x53).
/// TLV-encoded, mirroring `AnnouncementPacket`. Receivers MUST ignore
/// unknown TLV types (forward compatibility) and MUST reject payloads with
/// an unknown version or a missing/malformed npub.
struct SonarAnnouncePacket: Equatable {
    /// Raw BitchatPacket type byte reserved for Sonar discovery.
    /// Deliberately not added to the MessageType enum so bitchat's
    /// exhaustive switches stay untouched.
    static let packetType: UInt8 = 0x53
    /// Only version understood by this implementation.
    static let currentVersion: UInt8 = 1

    /// 32-byte x-only Nostr public key (raw bytes of the npub).
    let npub: Data
    /// Optional BIP-353 payment address ("user@domain", no leading ₿).
    let bip353: String?
    /// Capability bitfield (see `SonarCapability`).
    let capabilities: UInt8

    private enum TLVType: UInt8 {
        case version = 0x01
        case npub = 0x02
        case bip353 = 0x03
        case capabilities = 0x04
    }

    func encode() -> Data? {
        guard npub.count == 32 else { return nil }

        var data = Data()
        data.reserveCapacity(3 + 2 + npub.count + 2 + (bip353?.utf8.count ?? 0) + 3)

        // TLV for version
        data.append(TLVType.version.rawValue)
        data.append(1)
        data.append(Self.currentVersion)

        // TLV for npub (32 raw bytes, x-only Nostr public key)
        data.append(TLVType.npub.rawValue)
        data.append(UInt8(npub.count))
        data.append(npub)

        // TLV for BIP-353 payment address (optional)
        if let bip353 = bip353 {
            guard let bip353Data = bip353.data(using: .utf8), !bip353Data.isEmpty, bip353Data.count <= 255 else { return nil }
            data.append(TLVType.bip353.rawValue)
            data.append(UInt8(bip353Data.count))
            data.append(bip353Data)
        }

        // TLV for capabilities
        data.append(TLVType.capabilities.rawValue)
        data.append(1)
        data.append(capabilities)

        return data
    }

    static func decode(from data: Data) -> SonarAnnouncePacket? {
        // Normalize to zero-based indices (payloads can arrive as slices)
        let data = Data(data)
        var offset = 0
        var version: UInt8?
        var npub: Data?
        var bip353: String?
        var capabilities: UInt8?

        while offset + 2 <= data.count {
            let typeRaw = data[offset]
            offset += 1
            let length = Int(data[offset])
            offset += 1

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<offset + length]
            offset += length

            if let type = TLVType(rawValue: typeRaw) {
                switch type {
                case .version:
                    guard length == 1 else { return nil }
                    version = value.first
                case .npub:
                    npub = Data(value)
                case .bip353:
                    bip353 = String(data: value, encoding: .utf8)
                case .capabilities:
                    guard length == 1 else { return nil }
                    capabilities = value.first
                }
            } else {
                // Unknown TLV; skip (tolerant decoder for forward compatibility)
                continue
            }
        }

        // version, npub and capabilities are required; npub must be exactly
        // 32 bytes; an unknown version means we cannot interpret the payload.
        guard version == currentVersion,
              let npub = npub, npub.count == 32,
              let capabilities = capabilities else { return nil }

        return SonarAnnouncePacket(npub: npub, bip353: bip353, capabilities: capabilities)
    }
}

/// Local profile injected into BLEService by the app layer (no singletons):
/// when non-nil, a Sonar announce is broadcast after every bitchat announce.
struct SonarLocalProfile {
    /// 32-byte x-only Nostr public key (the Marmot identity npub).
    let npub: Data
    /// Optional BIP-353 payment address ("user@domain", no leading ₿).
    let bip353: String?
    /// Whether this device can actually RECEIVE payments (wallet configured).
    /// We only advertise the ⚡PAY capability when true, so peers never show
    /// "Send sats" toward someone who can't receive.
    let paymentsEnabled: Bool

    var capabilities: UInt8 {
        // Always speaks Marmot DMs and Sonar calls; ⚡PAY only when the wallet
        // is configured.
        var caps = SonarCapability.marmotDM | SonarCapability.calls
        if paymentsEnabled { caps |= SonarCapability.payments }
        return caps
    }
}

// MARK: - Receive-side notification

extension Notification.Name {
    /// Posted by BLEService when a signature-verified Sonar announce is
    /// received. userInfo: `SonarDiscoveryUserInfoKey.peerID` (String,
    /// PeerID.id) and `SonarDiscoveryUserInfoKey.profile` (SonarAnnouncePacket).
    static let sonarPeerProfileUpdated = Notification.Name("sonar.peerProfileUpdated")
}

enum SonarDiscoveryUserInfoKey {
    static let peerID = "peerID"
    static let profile = "profile"
}
