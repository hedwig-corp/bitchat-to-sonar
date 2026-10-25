import Foundation

// MARK: - Peer capabilities

/// Feature bits advertised in announce TLV 0x05 and proven inside a Noise
/// session by `AuthenticatedPeerStatePacket` (Noise payload 0x21).
///
/// Wire form: the minimal little-endian byte string (at least one byte, at
/// most eight). Unknown bits are kept on decode. Mirrors `PeerCapabilities`
/// in `core/bitchat-protocol/src/announce.rs` bit for bit.
struct PeerCapabilities: OptionSet, Hashable {
    let rawValue: UInt64

    init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Forward-secret async first contact (courier prekeys).
    static let prekeys = PeerCapabilities(rawValue: 1 << 0)
    /// Wi-Fi Aware bulk transfer.
    static let wifiBulk = PeerCapabilities(rawValue: 1 << 1)
    /// Mesh↔Nostr gateway.
    static let gateway = PeerCapabilities(rawValue: 1 << 2)
    /// Private groups.
    static let groups = PeerCapabilities(rawValue: 1 << 3)
    /// Geohash bulletin board.
    static let board = PeerCapabilities(rawValue: 1 << 4)
    /// Transitive verification vouches.
    static let vouch = PeerCapabilities(rawValue: 1 << 5)
    /// `/ping`, `/trace`.
    static let meshDiagnostics = PeerCapabilities(rawValue: 1 << 6)
    /// Bridges a rendezvous geohash cell.
    static let bridge = PeerCapabilities(rawValue: 1 << 7)
    /// Receives private media as Noise payload 0x20.
    static let privateMedia = PeerCapabilities(rawValue: 1 << 8)
    /// Sends delivery receipts for private media.
    static let privateMediaReceipts = PeerCapabilities(rawValue: 1 << 9)
    /// Reserved by upstream iOS; decode but never advertise.
    static let nonDestructiveNoiseReplacement = PeerCapabilities(rawValue: 1 << 10)

    /// What this build advertises and proves. Keep in lockstep with the
    /// receive side in `BLEService`: advertising a bit a peer will act on is a
    /// promise to accept the matching wire form.
    static let sonarLocal: PeerCapabilities = [.privateMedia, .privateMediaReceipts]

    /// Largest wire encoding.
    static let maxEncodedBytes = 8

    /// Minimal little-endian encoding (always at least one byte).
    func encoded() -> Data {
        var value = rawValue
        var out = Data()
        repeat {
            out.append(UInt8(value & 0xFF))
            value >>= 8
        } while value != 0
        return out
    }

    /// Decode the low 64 bits; extension bytes beyond 8 are ignored.
    init<C: Collection>(encoded bytes: C) where C.Element == UInt8 {
        var value: UInt64 = 0
        for (index, byte) in bytes.prefix(Self.maxEncodedBytes).enumerated() {
            value |= UInt64(byte) << UInt64(8 * index)
        }
        self.rawValue = value
    }

    /// Is `bytes` the minimal encoding of the value it decodes to?
    static func isCanonical<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= maxEncodedBytes else { return false }
        return PeerCapabilities(encoded: bytes).encoded().elementsEqual(bytes)
    }
}

// MARK: - Protocol TLV Packets

struct AnnouncementPacket {
    let nickname: String
    let noisePublicKey: Data            // Noise static public key (Curve25519.KeyAgreement)
    let signingPublicKey: Data          // Ed25519 public key for signing
    let directNeighbors: [Data]?        // 8-byte peer IDs
    /// Advertised feature bits (TLV 0x05); nil when the sender predates it.
    /// Advertised only — the proven set comes from `AuthenticatedPeerStatePacket`.
    var capabilities: PeerCapabilities? = nil
    /// Coarse rendezvous cell when bridging (TLV 0x06, ≤12 bytes).
    var bridgeGeohash: String? = nil
    /// TLVs this build does not understand, kept in arrival order and
    /// re-emitted after the known ones (as `Announce::unknown_tlvs` in the
    /// crate and `IdentityAnnouncement.unknownTLVs` on bitchat-android do), so
    /// re-encoding a decoded announce loses nothing a newer peer put in it.
    var unknownTLVs: [UnknownAnnouncementTLV] = []

    static let maxBridgeGeohashBytes = 12

    private enum TLVType: UInt8 {
        case nickname = 0x01
        case noisePublicKey = 0x02
        case signingPublicKey = 0x03
        case directNeighbors = 0x04
        case capabilities = 0x05
        case bridgeGeohash = 0x06
    }

    func encode() -> Data? {
        var data = Data()
        // Reserve: TLVs for nickname (2 + n), noise key (2 + 32), signing key (2 + 32)
        data.reserveCapacity(2 + min(nickname.count, 255) + 2 + noisePublicKey.count + 2 + signingPublicKey.count)

        // TLV for nickname
        guard let nicknameData = nickname.data(using: .utf8), nicknameData.count <= 255 else { return nil }
        data.append(TLVType.nickname.rawValue)
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)

        // TLV for noise public key
        guard noisePublicKey.count <= 255 else { return nil }
        data.append(TLVType.noisePublicKey.rawValue)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)

        // TLV for signing public key
        guard signingPublicKey.count <= 255 else { return nil }
        data.append(TLVType.signingPublicKey.rawValue)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)

        // TLV for direct neighbors (optional)
        if let neighbors = directNeighbors, !neighbors.isEmpty {
            let neighborsData = neighbors.prefix(10).reduce(Data()) { $0 + $1 }
            if !neighborsData.isEmpty && neighborsData.count % 8 == 0 {
                data.append(TLVType.directNeighbors.rawValue)
                data.append(UInt8(neighborsData.count))
                data.append(neighborsData)
            }
        }

        // TLV for capabilities (optional; minimal little-endian, 1..8 bytes)
        if let capabilities {
            let encoded = capabilities.encoded()
            data.append(TLVType.capabilities.rawValue)
            data.append(UInt8(encoded.count))
            data.append(encoded)
        }

        // TLV for bridge geohash (optional; skipped, not failed, when unusable)
        if let cell = bridgeGeohash?.data(using: .utf8),
           !cell.isEmpty,
           cell.count <= Self.maxBridgeGeohashBytes {
            data.append(TLVType.bridgeGeohash.rawValue)
            data.append(UInt8(cell.count))
            data.append(cell)
        }

        for tlv in unknownTLVs {
            guard tlv.value.count <= 255 else { return nil }
            data.append(tlv.type)
            data.append(UInt8(tlv.value.count))
            data.append(tlv.value)
        }

        return data
    }

    static func decode(from data: Data) -> AnnouncementPacket? {
        var offset = 0
        var nickname: String?
        var noisePublicKey: Data?
        var signingPublicKey: Data?
        var directNeighbors: [Data]?
        var capabilities: PeerCapabilities?
        var bridgeGeohash: String?
        var unknownTLVs: [UnknownAnnouncementTLV] = []

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
                case .nickname:
                    nickname = String(data: value, encoding: .utf8)
                case .noisePublicKey:
                    noisePublicKey = Data(value)
                case .signingPublicKey:
                    signingPublicKey = Data(value)
                case .directNeighbors:
                    if length > 0 && length % 8 == 0 {
                        var neighbors = [Data]()
                        let count = length / 8
                        for i in 0..<count {
                            let start = value.startIndex + i * 8
                            let end = start + 8
                            neighbors.append(Data(value[start..<end]))
                        }
                        directNeighbors = neighbors
                    }
                case .capabilities:
                    // Tolerant like the Rust announce decoder: any length
                    // decodes, extra bytes beyond eight are ignored.
                    capabilities = PeerCapabilities(encoded: value)
                case .bridgeGeohash:
                    if length <= Self.maxBridgeGeohashBytes {
                        bridgeGeohash = String(data: value, encoding: .utf8)
                    }
                }
            } else {
                // Unknown TLV: kept for re-encoding (tolerant decoder for
                // forward compatibility).
                unknownTLVs.append(UnknownAnnouncementTLV(type: typeRaw, value: Data(value)))
            }
        }

        guard let nickname = nickname, let noisePublicKey = noisePublicKey, let signingPublicKey = signingPublicKey else { return nil }
        return AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            directNeighbors: directNeighbors,
            capabilities: capabilities,
            bridgeGeohash: bridgeGeohash,
            unknownTLVs: unknownTLVs
        )
    }
}

/// An announce TLV this build does not understand.
struct UnknownAnnouncementTLV: Equatable {
    let type: UInt8
    let value: Data
}

/// Noise payload `0x21`: state that is authoritative only because it arrives
/// inside an established Noise session. The public announce's self-signature
/// cannot prove possession of the Noise key it carries; this can. Emitted once
/// after every completed handshake.
///
/// Wire: `[version=0x01][type][len][value]...` with TLV `0x01` = canonical
/// minimal little-endian capabilities (1–8 bytes) and `0x02` = 32-byte Ed25519
/// signing key. Strict decode: unknown version, duplicate TLV, non-canonical
/// capabilities, a key that is not 32 bytes, or a missing field rejects;
/// unknown TLV types are skipped. Mirrors `core/bitchat-protocol/src/peer_state.rs`.
struct AuthenticatedPeerStatePacket: Equatable {
    /// Proven feature bits.
    let capabilities: PeerCapabilities
    /// The Ed25519 key this peer signs announces and public messages with.
    let signingPublicKey: Data

    static let version: UInt8 = 0x01
    static let signingPublicKeyBytes = 32

    private enum TLVType: UInt8 {
        case capabilities = 0x01
        case signingPublicKey = 0x02
    }

    /// Encode (without the leading Noise payload type byte).
    func encode() -> Data? {
        let caps = capabilities.encoded()
        guard !caps.isEmpty, caps.count <= PeerCapabilities.maxEncodedBytes else { return nil }
        guard signingPublicKey.count == Self.signingPublicKeyBytes else { return nil }
        var out = Data()
        out.reserveCapacity(1 + 2 + caps.count + 2 + signingPublicKey.count)
        out.append(Self.version)
        out.append(TLVType.capabilities.rawValue)
        out.append(UInt8(caps.count))
        out.append(caps)
        out.append(TLVType.signingPublicKey.rawValue)
        out.append(UInt8(signingPublicKey.count))
        out.append(signingPublicKey)
        return out
    }

    /// Decode (input starts at the version byte).
    static func decode(from data: Data) -> AuthenticatedPeerStatePacket? {
        guard data.first == Self.version else { return nil }
        var capabilities: PeerCapabilities?
        var signingPublicKey: Data?
        var offset = data.startIndex + 1
        let end = data.endIndex
        while offset < end {
            guard offset + 2 <= end else { return nil }
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= end else { return nil }
            let value = data[offset..<offset + length]
            offset += length
            switch TLVType(rawValue: typeRaw) {
            case .capabilities:
                guard capabilities == nil, PeerCapabilities.isCanonical(value) else { return nil }
                capabilities = PeerCapabilities(encoded: value)
            case .signingPublicKey:
                guard signingPublicKey == nil, length == Self.signingPublicKeyBytes else { return nil }
                signingPublicKey = Data(value)
            case nil:
                continue
            }
        }
        guard let capabilities, let signingPublicKey else { return nil }
        return AuthenticatedPeerStatePacket(capabilities: capabilities, signingPublicKey: signingPublicKey)
    }
}

struct PrivateMessagePacket {
    let messageID: String
    let content: String
    var replyTo: String? = nil

    /// Largest field a stock bitchat client can decode (one-byte TLV length).
    static let legacyMaxFieldBytes = 255

    private enum TLVType: UInt8 {
        case messageID = 0x00
        case content = 0x01
        case messageIDLong = 0x02
        case contentLong = 0x03
        case replyTo = 0x04
        case replyToLong = 0x05
    }

    /// Can a stock bitchat client decode this message? Both reference
    /// decoders (bitchat iOS, bitchat-android) REJECT any TLV type they do not
    /// know and read one-byte lengths only, so a field over 255 bytes or a reply
    /// parent is not representable to them — the whole message vanishes.
    var fitsLegacy: Bool {
        messageID.utf8.count <= Self.legacyMaxFieldBytes
            && content.utf8.count <= Self.legacyMaxFieldBytes
            && (replyTo?.isEmpty ?? true)
    }

    /// Sonar's extended encoding: short TLVs when they fit (byte-identical to
    /// legacy), two-byte-length variants above 255 bytes, plus the reply
    /// parent. Only for peers that proved they are Sonar (verified 0x53).
    func encode() -> Data? {
        var data = Data()
        guard let messageIDData = messageID.data(using: .utf8), messageIDData.count <= UInt16.max else { return nil }
        guard let contentData = content.data(using: .utf8), contentData.count <= UInt16.max else { return nil }
        data.reserveCapacity(8 + messageIDData.count + contentData.count)

        appendTLV(.messageID, longType: .messageIDLong, value: messageIDData, to: &data)
        appendTLV(.content, longType: .contentLong, value: contentData, to: &data)
        if let replyData = replyTo?.data(using: .utf8),
           !replyData.isEmpty,
           replyData.count <= UInt16.max {
            appendTLV(.replyTo, longType: .replyToLong, value: replyData, to: &data)
        }

        return data
    }

    /// The reference encoding: `0x00 id` + `0x01 content`, one-byte lengths.
    /// Nil when a field exceeds 255 bytes; a `replyTo` is dropped (a stock
    /// peer could not read it anyway) — check `fitsLegacy` first if that loss
    /// matters. Mirrors `PrivateMessage::encode_legacy` in
    /// `core/bitchat-protocol/src/private_message.rs`.
    func encodeLegacy() -> Data? {
        guard let messageIDData = messageID.data(using: .utf8), messageIDData.count <= Self.legacyMaxFieldBytes else { return nil }
        guard let contentData = content.data(using: .utf8), contentData.count <= Self.legacyMaxFieldBytes else { return nil }
        var data = Data()
        data.reserveCapacity(4 + messageIDData.count + contentData.count)
        data.append(TLVType.messageID.rawValue)
        data.append(UInt8(messageIDData.count))
        data.append(messageIDData)
        data.append(TLVType.content.rawValue)
        data.append(UInt8(contentData.count))
        data.append(contentData)
        return data
    }

    /// Split UTF-8 `content` into pieces of at most `maxBytes` bytes on
    /// Unicode scalar boundaries, for delivery to a stock client one legacy
    /// message at a time. Always returns at least one piece (`[""]` for empty
    /// content). Mirrors `split_for_legacy`.
    static func splitForLegacy(_ content: String, maxBytes: Int = legacyMaxFieldBytes) -> [String] {
        let limit = max(maxBytes, 4) // room for any single UTF-8 scalar
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        var currentBytes = 0
        for scalar in content.unicodeScalars {
            let width = scalar.utf8.count
            if currentBytes + width > limit, currentBytes > 0 {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
                currentBytes = 0
            }
            current.append(scalar)
            currentBytes += width
        }
        if currentBytes > 0 || pieces.isEmpty {
            pieces.append(String(current))
        }
        return pieces
    }

    /// One Noise plaintext body (without the leading `0x01` type byte) and the
    /// message id it carries.
    struct WireFrame: Equatable {
        let messageID: String
        let tlv: Data
    }

    /// The TLV bodies to send for one private text, chosen for the recipient.
    ///
    /// A Sonar peer gets the extended TLVs in ONE message (reply parent, long
    /// fields). For any other peer — a stock bitchat client rejects a private
    /// message carrying a TLV it does not know and cannot represent a field over
    /// 255 bytes — the reply parent is not sent, and long text is delivered as
    /// a run of legacy-sized messages with ids `id`, `id#2`, `id#3`, ... The
    /// first piece keeps the caller's id so its delivery ack still maps onto
    /// the bubble. Mirrors `mesh_engine::try_send_text`. Nil only when a field
    /// cannot be encoded at all (e.g. id over 65535 bytes).
    static func wireFrames(messageID: String, content: String, replyTo: String?, peerIsSonar: Bool) -> [WireFrame]? {
        let message = PrivateMessagePacket(
            messageID: messageID,
            content: content,
            replyTo: replyTo.flatMap { trimmed in
                let value = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        )
        if peerIsSonar {
            guard let tlv = message.encode() else { return nil }
            return [WireFrame(messageID: messageID, tlv: tlv)]
        }
        if message.fitsLegacy {
            guard let tlv = message.encodeLegacy() else { return nil }
            return [WireFrame(messageID: messageID, tlv: tlv)]
        }
        var frames: [WireFrame] = []
        for (index, piece) in splitForLegacy(content).enumerated() {
            let id = index == 0 ? messageID : "\(messageID)#\(index + 1)"
            guard let tlv = PrivateMessagePacket(messageID: id, content: piece).encodeLegacy() else { return nil }
            frames.append(WireFrame(messageID: id, tlv: tlv))
        }
        return frames
    }

    private func appendTLV(_ type: TLVType, longType: TLVType, value: Data, to data: inout Data) {
        if value.count <= 255 {
            data.append(type.rawValue)
            data.append(UInt8(value.count))
        } else {
            data.append(longType.rawValue)
            data.append(UInt8((value.count >> 8) & 0xff))
            data.append(UInt8(value.count & 0xff))
        }
        data.append(value)
    }

    static func decode(from data: Data) -> PrivateMessagePacket? {
        var offset = 0
        var messageID: String?
        var content: String?
        var replyTo: String?

        // A trailing lone type byte is ignored, like both reference decoders
        // and the crate (`while offset + 2 <= count`).
        while offset + 2 <= data.count {
            let typeRaw = data[offset]
            offset += 1
            let type = TLVType(rawValue: typeRaw)

            let isLong = type == .messageIDLong || type == .contentLong || type == .replyToLong
            let length: Int
            if isLong {
                guard offset + 2 <= data.count else { return nil }
                length = (Int(data[offset]) << 8) | Int(data[offset + 1])
                offset += 2
            } else {
                // Known short types AND unknown types use a 1-byte length
                // (matches Rust PrivateMessage::decode). Skipping unknowns is
                // required so a newer peer's reply TLV cannot drop the PM.
                guard offset + 1 <= data.count else { return nil }
                length = Int(data[offset])
                offset += 1
            }

            guard offset + length <= data.count else { return nil }
            let value = data[offset..<(offset + length)]
            offset += length

            switch type {
            case .messageID, .messageIDLong:
                messageID = String(data: value, encoding: .utf8)
            case .content, .contentLong:
                content = String(data: value, encoding: .utf8)
            case .replyTo, .replyToLong:
                let parsed = String(data: value, encoding: .utf8)
                replyTo = parsed.flatMap { $0.isEmpty ? nil : $0 }
            case nil:
                break
            }
        }

        guard let messageID = messageID, let content = content else { return nil }
        return PrivateMessagePacket(messageID: messageID, content: content, replyTo: replyTo)
    }
}
