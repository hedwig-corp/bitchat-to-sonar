//
// SonarDiscoveryTests.swift
// bitchatTests
//
// Tests for the Sonar discovery announce payload (type 0x53), see
// docs/SONAR-DISCOVERY.md.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class SonarDiscoveryTests: XCTestCase {

    private let npub = Data((0..<32).map { UInt8($0) })

    // MARK: - TLV crafting helper

    private func tlv(_ type: UInt8, _ value: [UInt8]) -> Data {
        var data = Data()
        data.append(type)
        data.append(UInt8(value.count))
        data.append(contentsOf: value)
        return data
    }

    private func validPayload(version: UInt8 = 1, npubBytes: [UInt8]? = nil, capabilities: UInt8 = 0b01) -> Data {
        var data = Data()
        data.append(tlv(0x01, [version]))
        data.append(tlv(0x02, npubBytes ?? Array(npub)))
        data.append(tlv(0x04, [capabilities]))
        return data
    }

    // MARK: - Round trips

    func testRoundTripWithBip353() throws {
        let packet = SonarAnnouncePacket(
            npub: npub,
            bip353: "satoshi@example.org",
            capabilities: SonarCapability.marmotDM | SonarCapability.payments
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode Sonar announce")
        }
        guard let decoded = SonarAnnouncePacket.decode(from: encoded) else {
            return XCTFail("Failed to decode Sonar announce")
        }

        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.npub, npub)
        XCTAssertEqual(decoded.bip353, "satoshi@example.org")
        XCTAssertEqual(decoded.capabilities, 0b11)
    }

    func testRoundTripWithoutBip353() throws {
        let packet = SonarAnnouncePacket(
            npub: npub,
            bip353: nil,
            capabilities: SonarCapability.marmotDM
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode Sonar announce")
        }
        guard let decoded = SonarAnnouncePacket.decode(from: encoded) else {
            return XCTFail("Failed to decode Sonar announce")
        }

        XCTAssertEqual(decoded, packet)
        XCTAssertNil(decoded.bip353)
        XCTAssertEqual(decoded.capabilities, 0b01)
    }

    func testDecodeToleratesDataSlices() throws {
        let packet = SonarAnnouncePacket(npub: npub, bip353: nil, capabilities: 0b01)
        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode Sonar announce")
        }
        // Simulate a payload arriving as a non-zero-based slice
        var prefixed = Data([0xAA, 0xBB, 0xCC])
        prefixed.append(encoded)
        let slice = prefixed[3...]

        XCTAssertEqual(SonarAnnouncePacket.decode(from: slice), packet)
    }

    // MARK: - Forward compatibility

    func testDecodeIgnoresUnknownTLVs() throws {
        // Unknown TLVs interleaved before, between and after the known ones
        var data = Data()
        data.append(tlv(0x7F, [0xDE, 0xAD, 0xBE, 0xEF]))      // unknown
        data.append(tlv(0x01, [1]))                            // version
        data.append(tlv(0x60, Array("future".utf8)))           // unknown
        data.append(tlv(0x02, Array(npub)))                    // npub
        data.append(tlv(0x04, [0b01]))                         // capabilities
        data.append(tlv(0xF0, []))                             // unknown, empty

        guard let decoded = SonarAnnouncePacket.decode(from: data) else {
            return XCTFail("Decoder must skip unknown TLVs")
        }
        XCTAssertEqual(decoded.npub, npub)
        XCTAssertNil(decoded.bip353)
        XCTAssertEqual(decoded.capabilities, 0b01)
    }

    // MARK: - Rejections

    func testDecodeRejectsUnknownVersion() {
        XCTAssertNil(SonarAnnouncePacket.decode(from: validPayload(version: 2)))
    }

    func testDecodeRejectsMissingVersion() {
        var data = Data()
        data.append(tlv(0x02, Array(npub)))
        data.append(tlv(0x04, [0b01]))
        XCTAssertNil(SonarAnnouncePacket.decode(from: data))
    }

    func testDecodeRejectsShortNpub() {
        XCTAssertNil(SonarAnnouncePacket.decode(from: validPayload(npubBytes: Array(npub.prefix(31)))))
    }

    func testDecodeRejectsMissingNpub() {
        var data = Data()
        data.append(tlv(0x01, [1]))
        data.append(tlv(0x04, [0b01]))
        XCTAssertNil(SonarAnnouncePacket.decode(from: data))
    }

    func testDecodeRejectsMissingCapabilities() {
        var data = Data()
        data.append(tlv(0x01, [1]))
        data.append(tlv(0x02, Array(npub)))
        XCTAssertNil(SonarAnnouncePacket.decode(from: data))
    }

    func testDecodeRejectsTruncatedTLV() {
        // Length byte claims more data than is present
        var data = validPayload()
        data.append(contentsOf: [0x03, 0x10, 0x41]) // bip353 TLV claiming 16 bytes, 1 present
        XCTAssertNil(SonarAnnouncePacket.decode(from: data))
    }

    func testEncodeRejectsWrongNpubLength() {
        let short = SonarAnnouncePacket(npub: Data(repeating: 0x01, count: 31), bip353: nil, capabilities: 0b01)
        XCTAssertNil(short.encode())
        let long = SonarAnnouncePacket(npub: Data(repeating: 0x01, count: 33), bip353: nil, capabilities: 0b01)
        XCTAssertNil(long.encode())
    }

    // MARK: - Local profile capabilities

    func testLocalProfileCapabilities() {
        // This build always speaks Marmot DMs + the ⚡PAY convention,
        // regardless of whether a BIP-353 address is advertised.
        XCTAssertEqual(
            SonarLocalProfile(npub: npub, bip353: nil).capabilities,
            SonarCapability.marmotDM | SonarCapability.payments
        )
        XCTAssertEqual(
            SonarLocalProfile(npub: npub, bip353: "satoshi@example.org").capabilities,
            SonarCapability.marmotDM | SonarCapability.payments
        )
    }
}
