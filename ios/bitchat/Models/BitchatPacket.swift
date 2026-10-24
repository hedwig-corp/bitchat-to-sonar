//
// BitchatPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// The payload bytes exactly as they arrived on the wire, kept beside the
/// decoded payload so a re-encode (relay TTL decrement, signature
/// verification) reproduces the originator's bytes instead of running our own
/// DEFLATE encoder over the payload.
///
/// DEFLATE output is encoder-specific: Apple's `Compression` framework, Rust
/// miniz (Sonar Android) and `java.util.zip` (bitchat-android) all emit
/// different streams for the same input, and a sender may also have chosen
/// NOT to compress a payload we would compress. Either way, rebuilding the
/// signature preimage with our encoder rejects every valid signed packet whose
/// payload is compressible (≥ `TransportConfig.compressionThresholdBytes`).
/// Mirrors `WirePayload` in `core/bitchat-protocol/src/packet.rs` and upstream
/// bitchat-android #863 ("preserve wire payload").
///
/// `payloadSHA256` ties the bytes to the payload they decode to: change the
/// payload and the encoder compresses afresh.
struct WirePayload {
    /// Compressed stream when `compressed`, else the raw payload.
    let bytes: Data
    /// Whether `bytes` is a DEFLATE stream.
    let compressed: Bool
    /// SHA-256 of the decoded payload these bytes belong to.
    let payloadSHA256: Data

    init(bytes: Data, compressed: Bool, forPayload payload: Data) {
        self.bytes = bytes
        self.compressed = compressed
        self.payloadSHA256 = payload.sha256Hash()
    }

    /// Do these wire bytes still describe `payload`?
    func matches(_ payload: Data) -> Bool {
        payloadSHA256 == payload.sha256Hash()
    }
}

/// The core packet structure for all BitChat protocol messages.
/// Encapsulates all data needed for routing through the mesh network,
/// including TTL for hop limiting and optional encryption.
/// - Note: Packets larger than BLE MTU (512 bytes) are automatically fragmented
struct BitchatPacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    var signature: Data?
    var ttl: UInt8
    var route: [Data]?
    var isRSR: Bool
    /// Payload bytes as received; `nil` for a locally built packet. Not part of
    /// the coded form and not an identity property: two packets with the same
    /// fields are the same packet whether or not one remembers its wire bytes.
    var wirePayload: WirePayload? = nil

    private enum CodingKeys: String, CodingKey {
        case version, type, senderID, recipientID, timestamp, payload, signature, ttl, route, isRSR
    }

    init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8, version: UInt8 = 1, route: [Data]? = nil, isRSR: Bool = false) {
        self.version = version
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.ttl = ttl
        self.route = route
        self.isRSR = isRSR
    }

    // Convenience initializer for new binary format
    init(type: UInt8, ttl: UInt8, senderID: PeerID, payload: Data, isRSR: Bool = false) {
        self.version = 1
        self.type = type
        // Convert hex string peer ID to binary data (8 bytes)
        var senderData = Data()
        var tempID = senderID.id
        while tempID.count >= 2 {
            let hexByte = String(tempID.prefix(2))
            if let byte = UInt8(hexByte, radix: 16) {
                senderData.append(byte)
            }
            tempID = String(tempID.dropFirst(2))
        }
        self.senderID = senderData
        self.recipientID = nil
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
        self.payload = payload
        self.signature = nil
        self.ttl = ttl
        self.route = nil
        self.isRSR = isRSR
    }

    var data: Data? {
        BinaryProtocol.encode(self)
    }

    func toBinaryData(padding: Bool = true) -> Data? {
        BinaryProtocol.encode(self, padding: padding)
    }

    // Backward-compatible helper (defaults to padded encoding)
    func toBinaryData() -> Data? {
        toBinaryData(padding: true)
    }

    /// Create binary representation for signing (without signature and TTL fields)
    /// TTL is excluded because it changes during packet relay operations
    func toBinaryDataForSigning() -> Data? {
        // Create a copy without signature and with fixed TTL for signing
        // TTL must be excluded because it changes during relay
        var unsignedPacket = BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: nil, // Remove signature for signing
            ttl: 0, // Use fixed TTL=0 for signing to ensure relay compatibility
            version: version,
            route: route,
            isRSR: false // RSR flag is mutable and not part of the signature
        )
        // A verifier must rebuild the preimage from the bytes the ORIGINATOR
        // put on the wire, never from a re-compression of the payload (see
        // `WirePayload`). For a locally built packet this is nil and the
        // encoder decides compression exactly as before.
        unsignedPacket.wirePayload = wirePayload
        return BinaryProtocol.encode(unsignedPacket)
    }

    static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}
