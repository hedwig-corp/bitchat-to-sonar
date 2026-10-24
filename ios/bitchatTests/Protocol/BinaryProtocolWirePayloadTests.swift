import XCTest
import CryptoKit
@testable import Sonar

/// Signature preimages must be rebuilt from the bytes the ORIGINATOR put on
/// the wire, never from a re-compression of the decoded payload. DEFLATE
/// output is encoder-specific (Apple `Compression` vs Rust miniz on Sonar
/// Android vs `java.util.zip` on bitchat-android), and a sender may have left
/// a compressible payload plain; either way a re-encode changes the preimage
/// and every such signed packet fails verification. Mirrors the
/// `WirePayload` tests in `core/bitchat-protocol/src/packet.rs` / `signing.rs`.
final class BinaryProtocolWirePayloadTests: XCTestCase {

    private let sender = Data([0, 1, 2, 3, 4, 5, 6, 7])
    private let timestamp: UInt64 = 0x0102_0304_0506_0708
    /// 360 bytes, far over `TransportConfig.compressionThresholdBytes` (100)
    /// and well under 90% unique bytes, so `shouldCompress` says yes.
    private var compressiblePayload: Data {
        Data(String(repeating: "compress-me ", count: 30).utf8)
    }

    /// Hand-assembled v1 frame: header(14) + sender(8) + body. No recipient,
    /// no signature, no padding.
    private func v1Frame(type: UInt8, ttl: UInt8, flags: UInt8, body: Data) -> Data {
        var frame = Data([1, type, ttl])
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((timestamp >> UInt64(shift)) & 0xFF))
        }
        frame.append(flags)
        let length = UInt16(body.count)
        frame.append(UInt8(length >> 8))
        frame.append(UInt8(length & 0xFF))
        frame.append(sender)
        frame.append(body)
        return frame
    }

    /// A valid raw DEFLATE stream Apple's encoder never emits for this input:
    /// a single stored (uncompressed) block, RFC 1951 §3.2.4.
    private func storedDeflate(_ payload: Data) -> Data {
        var out = Data([0x01]) // BFINAL=1, BTYPE=00, byte-aligned
        let len = UInt16(payload.count)
        out.append(UInt8(len & 0xFF))
        out.append(UInt8(len >> 8))
        let nlen = ~len
        out.append(UInt8(nlen & 0xFF))
        out.append(UInt8(nlen >> 8))
        out.append(payload)
        return out
    }

    private func fresh(type: UInt8, ttl: UInt8, payload: Data) -> BitchatPacket {
        BitchatPacket(
            type: type,
            senderID: sender,
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: ttl
        )
    }

    // MARK: 1. A foreign compressed stream is reproduced byte for byte

    func testReencodeReproducesAForeignDeflateStream() throws {
        let payload = compressiblePayload
        let stream = storedDeflate(payload)
        var body = Data()
        body.append(UInt8(payload.count >> 8))
        body.append(UInt8(payload.count & 0xFF))
        body.append(stream)
        let frame = v1Frame(type: 0x02, ttl: 7, flags: BinaryProtocol.Flags.isCompressed, body: body)

        let decoded = try XCTUnwrap(BinaryProtocol.decode(frame), "stored-block deflate must decode")
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.wirePayload?.compressed, true)
        XCTAssertEqual(decoded.wirePayload?.bytes, stream)

        // Our encoder would have produced a different (smaller) stream...
        let ours = try XCTUnwrap(fresh(type: 0x02, ttl: 7, payload: payload).toBinaryData(padding: false))
        XCTAssertNotEqual(ours, frame, "precondition: Apple's DEFLATE differs from the hand-built stream")
        XCTAssertLessThan(ours.count, frame.count)

        // ...but a decoded packet re-encodes to exactly what arrived.
        XCTAssertEqual(decoded.toBinaryData(padding: false), frame)
        // Padded form (the shape the signature preimage uses) is the padded
        // original, not a padded re-compression.
        let padded = try XCTUnwrap(decoded.toBinaryData(padding: true))
        XCTAssertEqual(padded, MessagePadding.pad(frame, toSize: MessagePadding.optimalBlockSize(for: frame.count)))
        XCTAssertEqual(BinaryProtocol.decode(padded)?.payload, payload)
    }

    func testReencodeReproducesOurOwnCompressedFrame() throws {
        let frame = try XCTUnwrap(fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryData(padding: false))
        XCTAssertNotEqual(frame[11] & BinaryProtocol.Flags.isCompressed, 0)
        let decoded = try XCTUnwrap(BinaryProtocol.decode(frame))
        XCTAssertEqual(decoded.toBinaryData(padding: false), frame)
    }

    // MARK: 2. Signed over an UNCOMPRESSED but compressible payload

    func testSignatureOverUncompressedCompressiblePayloadVerifies() throws {
        // 120 identical bytes: over the threshold, trivially compressible,
        // sent plain (flags without 0x04) — what a sender that does not
        // compress produces.
        let payload = Data(repeating: 0x41, count: 120)
        XCTAssertTrue(CompressionUtil.shouldCompress(payload), "precondition: we WOULD compress this")
        let frame = v1Frame(type: 0x02, ttl: 7, flags: 0, body: payload)

        let decoded = try XCTUnwrap(BinaryProtocol.decode(frame))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.wirePayload?.compressed, false)

        // The preimage is the canonical (ttl 0, unsigned, padded) form of the
        // frame AS SENT: still uncompressed.
        let preimage = try XCTUnwrap(decoded.toBinaryDataForSigning())
        XCTAssertEqual(preimage[11] & BinaryProtocol.Flags.isCompressed, 0)
        var canonical = frame
        canonical[2] = 0 // ttl
        XCTAssertEqual(preimage, MessagePadding.pad(canonical, toSize: MessagePadding.optimalBlockSize(for: canonical.count)))

        // The sender signs that preimage; a CryptoKit verifier (what
        // NoiseEncryptionService.verifySignature wraps) accepts it.
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: preimage)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: preimage))

        // A packet built fresh from the same fields re-compresses and yields a
        // DIFFERENT preimage — the pre-fix behaviour, and why every such packet
        // from Android failed verification.
        let freshPreimage = try XCTUnwrap(fresh(type: 0x02, ttl: 7, payload: payload).toBinaryDataForSigning())
        XCTAssertNotEqual(freshPreimage[11] & BinaryProtocol.Flags.isCompressed, 0)
        XCTAssertNotEqual(freshPreimage, preimage)
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: freshPreimage))

        // Relay round trip: attach the signature, change the mutable fields,
        // encode, decode again — the receiver's preimage still verifies.
        var signed = decoded
        signed.signature = signature
        signed.ttl = 3
        signed.isRSR = true
        let wire = try XCTUnwrap(signed.toBinaryData(padding: false))
        XCTAssertEqual(wire[11] & BinaryProtocol.Flags.isCompressed, 0, "relay must not compress the payload either")
        let relayed = try XCTUnwrap(BinaryProtocol.decode(wire))
        XCTAssertEqual(relayed.ttl, 3)
        XCTAssertEqual(relayed.signature, signature)
        let relayedPreimage = try XCTUnwrap(relayed.toBinaryDataForSigning())
        XCTAssertEqual(relayedPreimage, preimage)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: relayedPreimage))
    }

    // MARK: 3. Changing the payload drops the remembered wire bytes

    func testChangedPayloadIsCompressedAfreshNotReplayed() throws {
        let frame = try XCTUnwrap(fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryData(padding: false))
        let decoded = try XCTUnwrap(BinaryProtocol.decode(frame))
        XCTAssertEqual(decoded.wirePayload?.compressed, true)

        let other = Data(String(repeating: "something else entirely, also long and repetitive ", count: 6).utf8)
        XCTAssertNotEqual(other, decoded.payload)
        // `payload` is immutable, so the stale wire bytes travel with a new
        // packet value — the SHA-256 guard must notice the mismatch.
        var changed = fresh(type: decoded.type, ttl: decoded.ttl, payload: other)
        changed.wirePayload = decoded.wirePayload
        XCTAssertEqual(changed.wirePayload?.matches(other), false)

        let bytes = try XCTUnwrap(changed.toBinaryData(padding: false))
        XCTAssertNotEqual(bytes, frame)
        let redecoded = try XCTUnwrap(BinaryProtocol.decode(bytes))
        XCTAssertEqual(redecoded.payload, other)
        XCTAssertNotEqual(bytes[11] & BinaryProtocol.Flags.isCompressed, 0, "a compressible payload is still compressed when encoded fresh")
    }

    func testWirePayloadIsNotPartOfTheCodedForm() throws {
        let frame = try XCTUnwrap(fresh(type: 0x02, ttl: 7, payload: compressiblePayload).toBinaryData(padding: false))
        let decoded = try XCTUnwrap(BinaryProtocol.decode(frame))
        let json = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("wirePayload"))
        let restored = try JSONDecoder().decode(BitchatPacket.self, from: json)
        XCTAssertNil(restored.wirePayload)
        XCTAssertEqual(restored.payload, decoded.payload)
    }
}
