import XCTest
@testable import Sonar

/// Both reference decoders (bitchat iOS, bitchat-android) reject a private
/// message carrying any TLV they do not know and read one-byte lengths only.
/// Sonar's extensions (0x02/0x03 long fields, 0x04/0x05 reply parent) may
/// therefore only go to a peer that proved it is Sonar; everyone else gets the
/// legacy form, split when it does not fit. Mirrors
/// `core/bitchat-protocol/src/private_message.rs` and `mesh_engine::try_send_text`.
final class PrivateMessagePacketLegacyTests: XCTestCase {

    /// Parse a TLV body the way a STOCK client does: one-byte lengths, and any
    /// unknown type is fatal. Returns the types seen, or nil on rejection.
    private func stockDecodeTypes(_ data: Data) -> [UInt8]? {
        var offset = 0
        var types: [UInt8] = []
        while offset + 2 <= data.count {
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard type == 0x00 || type == 0x01 else { return nil }
            guard offset + length <= data.count else { return nil }
            offset += length
            types.append(type)
        }
        return types
    }

    func testLegacyAndExtendedAgreeOnShortFields() throws {
        let message = PrivateMessagePacket(messageID: "m1", content: "hi")
        let legacy = try XCTUnwrap(message.encodeLegacy())
        XCTAssertEqual(Array(legacy), [0x00, 2, 0x6D, 0x31, 0x01, 2, 0x68, 0x69])
        XCTAssertEqual(message.encode(), legacy)
        XCTAssertTrue(message.fitsLegacy)
        let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: legacy))
        XCTAssertEqual(decoded.messageID, "m1")
        XCTAssertEqual(decoded.content, "hi")
        XCTAssertNil(decoded.replyTo)
    }

    func testLongContentUsesTwoByteLengthOnlyInExtended() throws {
        let message = PrivateMessagePacket(messageID: "id", content: String(repeating: "a", count: 300))
        XCTAssertFalse(message.fitsLegacy)
        XCTAssertNil(message.encodeLegacy())
        let extended = try XCTUnwrap(message.encode())
        XCTAssertEqual(extended[4], 0x03)
        XCTAssertEqual(Array(extended[5..<7]), [0x01, 0x2C])
        XCTAssertEqual(PrivateMessagePacket.decode(from: extended)?.content, message.content)
        XCTAssertNil(stockDecodeTypes(extended), "a stock client rejects the 0x03 TLV")

        let exact = PrivateMessagePacket(messageID: "id", content: String(repeating: "a", count: 255))
        XCTAssertTrue(exact.fitsLegacy)
        XCTAssertEqual(exact.encodeLegacy(), exact.encode())
    }

    func testReplyToIsExtendedOnlyAndDroppedByLegacy() throws {
        let message = PrivateMessagePacket(messageID: "m1", content: "hi", replyTo: "parent")
        XCTAssertFalse(message.fitsLegacy)
        let legacy = try XCTUnwrap(message.encodeLegacy())
        XCTAssertNil(PrivateMessagePacket.decode(from: legacy)?.replyTo)
        XCTAssertEqual(stockDecodeTypes(legacy), [0x00, 0x01])

        let extended = try XCTUnwrap(message.encode())
        XCTAssertEqual(extended[8], 0x04)
        XCTAssertEqual(PrivateMessagePacket.decode(from: extended)?.replyTo, "parent")
        XCTAssertNil(stockDecodeTypes(extended), "a stock client rejects the 0x04 TLV")

        let emptyReply = PrivateMessagePacket(messageID: "m1", content: "hi", replyTo: "")
        XCTAssertTrue(emptyReply.fitsLegacy)
        XCTAssertEqual(emptyReply.encode(), legacy)
    }

    func testSplitForLegacyRespectsScalarBoundaries() {
        let content = String(repeating: "é", count: 300) // 2 bytes each → 600 bytes
        let pieces = PrivateMessagePacket.splitForLegacy(content, maxBytes: 255)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertTrue(pieces.allSatisfy { $0.utf8.count <= 255 })
        XCTAssertEqual(pieces.joined(), content)
        // 255 is odd, so a 2-byte scalar never straddles: 254 + 254 + 92 bytes.
        XCTAssertEqual(pieces.map { $0.utf8.count }, [254, 254, 92])

        XCTAssertEqual(PrivateMessagePacket.splitForLegacy("", maxBytes: 255), [""])
        XCTAssertEqual(PrivateMessagePacket.splitForLegacy("abc", maxBytes: 255), ["abc"])

        // Four-byte scalars with a tiny limit: one per piece, never torn.
        let emoji = String(repeating: "😀", count: 3)
        XCTAssertEqual(PrivateMessagePacket.splitForLegacy(emoji, maxBytes: 1), ["😀", "😀", "😀"])
    }

    // MARK: - Send-site shaping (what BLEService hands to the Noise session)

    func testStockPeerGetsSplitLegacyFramesWithDerivedIDs() throws {
        let content = String(repeating: "x", count: 600)
        let frames = try XCTUnwrap(PrivateMessagePacket.wireFrames(
            messageID: "abc",
            content: content,
            replyTo: "parent",
            peerIsSonar: false
        ))
        XCTAssertEqual(frames.map(\.messageID), ["abc", "abc#2", "abc#3"])
        var reassembled = ""
        for frame in frames {
            XCTAssertEqual(stockDecodeTypes(frame.tlv), [0x00, 0x01], "every piece must be stock-decodable")
            let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: frame.tlv))
            XCTAssertNil(decoded.replyTo, "a reply parent is not representable to a stock peer")
            XCTAssertLessThanOrEqual(decoded.content.utf8.count, 255)
            reassembled += decoded.content
        }
        XCTAssertEqual(reassembled, content)
    }

    func testStockPeerShortReplyIsOneLegacyFrameWithoutParent() throws {
        let frames = try XCTUnwrap(PrivateMessagePacket.wireFrames(
            messageID: "abc",
            content: "hi",
            replyTo: "parent",
            peerIsSonar: false
        ))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].messageID, "abc")
        XCTAssertEqual(stockDecodeTypes(frames[0].tlv), [0x00, 0x01])
        XCTAssertNil(PrivateMessagePacket.decode(from: frames[0].tlv)?.replyTo)
    }

    func testSonarPeerGetsOneExtendedFrame() throws {
        let content = String(repeating: "x", count: 600)
        let frames = try XCTUnwrap(PrivateMessagePacket.wireFrames(
            messageID: "abc",
            content: content,
            replyTo: " parent ",
            peerIsSonar: true
        ))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].messageID, "abc")
        let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: frames[0].tlv))
        XCTAssertEqual(decoded.content, content)
        XCTAssertEqual(decoded.replyTo, "parent")
    }

    func testStockPeerShortPlainTextIsByteIdenticalToExtended() throws {
        let stock = try XCTUnwrap(PrivateMessagePacket.wireFrames(messageID: "m", content: "hello", replyTo: nil, peerIsSonar: false))
        let sonar = try XCTUnwrap(PrivateMessagePacket.wireFrames(messageID: "m", content: "hello", replyTo: nil, peerIsSonar: true))
        XCTAssertEqual(stock, sonar)
    }
}
