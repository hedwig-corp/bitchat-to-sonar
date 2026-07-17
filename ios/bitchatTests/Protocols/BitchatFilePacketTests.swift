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

    func testEncodeRejectsExplicitEmptyMessageID() {
        let packet = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: 1,
            mimeType: "image/jpeg",
            messageID: "",
            content: Data([0x01])
        )

        XCTAssertNil(packet.encode())
    }
}
