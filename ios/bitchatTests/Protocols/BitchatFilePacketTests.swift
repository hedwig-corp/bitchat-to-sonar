import XCTest
@testable import Sonar

final class BitchatFilePacketTests: XCTestCase {
    func testVideoNoteRoleRoundTripsAndRemainsOptional() throws {
        let bytes = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        let packet = BitchatFilePacket(
            fileName: "note.mp4",
            fileSize: UInt64(bytes.count),
            mimeType: "video/mp4",
            mediaRole: .videoNote,
            content: bytes
        )
        let encoded = try XCTUnwrap(packet.encode())
        let decoded = try XCTUnwrap(BitchatFilePacket.decode(encoded))
        XCTAssertEqual(decoded.mediaRole, .videoNote)
        XCTAssertEqual(decoded.content, bytes)

        let knownRole = Data([0x05, 0x00, 0x0A]) + Data("video_note".utf8)
        let roleRange = try XCTUnwrap(encoded.range(of: knownRole))
        var futureRole = encoded
        futureRole.replaceSubrange(
            roleRange,
            with: Data([0x05, 0x00, 0x06]) + Data("future".utf8)
        )
        let futureDecoded = try XCTUnwrap(BitchatFilePacket.decode(futureRole))
        XCTAssertNil(futureDecoded.mediaRole)
        XCTAssertEqual(futureDecoded.content, bytes)

        let mismatched = BitchatFilePacket(
            fileName: "not-a-video.jpg",
            fileSize: UInt64(bytes.count),
            mimeType: "image/jpeg",
            mediaRole: .videoNote,
            content: bytes
        )
        let mismatchedDecoded = try XCTUnwrap(
            BitchatFilePacket.decode(try XCTUnwrap(mismatched.encode()))
        )
        XCTAssertNil(mismatchedDecoded.mediaRole)
        XCTAssertEqual(mismatchedDecoded.content, bytes)
    }

    func testRoundTripPreservesFields() throws {
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        let packet = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
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
}
