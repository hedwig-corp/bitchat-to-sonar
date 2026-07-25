import XCTest
@testable import Sonar

final class BitchatFilePacketTests: XCTestCase {

    func testRoundTripPreservesFields() throws {
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        let packet = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            messageID: "media-message-1",
            content: content
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode file packet")
        }
        guard let decoded = BitchatFilePacket.decode(encoded) else {
            return XCTFail("Failed to decode file packet")
        }

        XCTAssertEqual(decoded.fileName, packet.fileName)
        XCTAssertEqual(decoded.fileSize, packet.fileSize)
        XCTAssertEqual(decoded.mimeType, packet.mimeType)
        XCTAssertEqual(decoded.messageID, packet.messageID)
        XCTAssertEqual(decoded.content, packet.content)
    }

    func testDecodeFallsBackToContentSizeWhenFileSizeMissing() throws {
        let content = Data(repeating: 0x7F, count: 1024)
        let packet = BitchatFilePacket(
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            content: content
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode file packet")
        }
        guard let decoded = BitchatFilePacket.decode(encoded) else {
            return XCTFail("Failed to decode file packet")
        }

        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }

    /// The message id is an OPTIONAL extension whose only job is to enable a
    /// delivery receipt. An unusable one must cost the receipt, never the
    /// transfer — the previous behaviour returned nil and dropped the media.
    /// Mirrors `mesh.rs::malformed_optional_message_id_degrades_instead_of_dropping_the_file`.
    func testUnusableMessageIDCostsTheReceiptNotTheTransfer() {
        let content = Data([0x01, 0x02, 0x03])

        for unusableID in ["", String(repeating: "x", count: Int(UInt16.max) + 1)] {
            let packet = BitchatFilePacket(
                fileName: "sample.jpg",
                fileSize: UInt64(content.count),
                mimeType: "image/jpeg",
                messageID: unusableID,
                content: content
            )
            guard let encoded = packet.encode() else {
                return XCTFail("an unusable message id must not fail the send")
            }
            let decoded = BitchatFilePacket.decode(encoded)
            XCTAssertNotNil(decoded)
            XCTAssertNil(decoded?.messageID, "no receipt hint survives")
            XCTAssertEqual(decoded?.content, content, "but the media does")
            XCTAssertEqual(decoded?.mimeType, "image/jpeg")
        }
    }

    /// A 0x05 value that is not valid UTF-8 must not fail the whole decode.
    func testMalformedMessageIDTLVStillDecodesTheFile() {
        let content = Data([0x0A, 0x0B])
        var raw = Data()
        raw.append(0x03)                                  // MIME_TYPE
        raw.append(contentsOf: [0x00, 0x0A])
        raw.append(contentsOf: Array("image/jpeg".utf8))
        raw.append(0x05)                                  // MESSAGE_ID, invalid UTF-8
        raw.append(contentsOf: [0x00, 0x02])
        raw.append(contentsOf: [0xFF, 0xFE])
        raw.append(0x04)                                  // CONTENT
        raw.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        raw.append(content)

        let decoded = BitchatFilePacket.decode(raw)
        XCTAssertNotNil(decoded, "a malformed optional TLV must not drop the file")
        XCTAssertNil(decoded?.messageID)
        XCTAssertEqual(decoded?.content, content)
    }

    /// `isEncodable` is the cheap precondition the image send path uses instead
    /// of a throwaway full encode on the MainActor, so it has to agree with
    /// `encode()` on both answers.
    func testIsEncodableAgreesWithEncode() {
        let ok = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: 2,
            mimeType: "image/jpeg",
            messageID: "mid-1",
            content: Data([0x01, 0x02])
        )
        XCTAssertTrue(ok.isEncodable)
        XCTAssertNotNil(ok.encode())

        let tooBig = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: UInt64(FileTransferLimits.maxPayloadBytes) + 1,
            mimeType: "image/jpeg",
            messageID: "mid-1",
            content: Data([0x01, 0x02])
        )
        XCTAssertFalse(tooBig.isEncodable)
        XCTAssertNil(tooBig.encode())
    }
}
