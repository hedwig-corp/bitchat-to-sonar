//
// UnifyReceiverTests.swift
// bitchatTests
//
// Tests for the Unify nearby-payments RECEIVER role (Sonar getting paid by a
// Unify user). The receiver serves `frame("bitcoin:?lno=<offer>")` from a GATT
// characteristic and advertises the user's nickname as the v2 display name.
//
// Two things are verified here:
//   1. Our `frame()` output decodes correctly via the payer's `Reassembler`
//      (round-trip), including a >1 KB offer and the offset-slicing a GATT long
//      READ performs (the inverse of the payer's reassembly).
//   2. The advertised-name handling: the manufacturer-data 0xFFFF parse and the
//      contract sanitize/trim + 20-byte UTF-8 cap.
// See docs/UNIFY-INTEROP.md.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
@testable import bitchat

final class UnifyReceiverTests: XCTestCase {

    private let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"

    // MARK: - frame() ⇄ Reassembler round-trip (the receiver/payer inverse)

    /// The framed amountless BIP321 payload the receiver serves decodes back to
    /// the same string via the payer's reassembler in a single read.
    func testServedPayloadRoundTripsSingleRead() throws {
        let payload = "bitcoin:?lno=\(offer)"
        let framed = try UnifyNearbyFraming.frame(payload)
        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertEqual(try r.offer(framed), payload)
        XCTAssertTrue(r.isComplete)
    }

    /// A >1 KB offer (still well under MAX_PAYLOAD_BYTES) frames and round-trips.
    func testLargeOfferRoundTrips() throws {
        let bigOffer = "lno1" + String(repeating: "qsgq", count: 400) // ~1.6 KB
        let payload = "bitcoin:?lno=\(bigOffer)"
        XCTAssertGreaterThan(payload.utf8.count, 1024)
        let framed = try UnifyNearbyFraming.frame(payload)
        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertEqual(try r.offer(framed), payload)
    }

    /// Simulate the GATT long READ: CoreBluetooth hands the framed blob to the
    /// central as a sequence of MTU-sized slices starting at increasing
    /// offsets, exactly as `peripheralManager(_:didReceiveRead:)` returns
    /// `framed.subdata(in: offset..<count)`. The payer reassembles them.
    func testOffsetSlicedLongReadRoundTrips() throws {
        let payload = "bitcoin:?lno=\(offer)"
        let framed = try UnifyNearbyFraming.frame(payload)

        // The central concatenates the offset slices; mirror that here.
        let mtuPayload = 20 // worst case (default ATT MTU 23 → 20 usable)
        var reassembledBlob = Data()
        var offset = 0
        while offset < framed.count {
            // This is precisely the slice UnifyReceiverService serves at `offset`.
            let slice = framed.subdata(in: offset..<framed.count)
            // CoreBluetooth would cap each delivery at the MTU; take that prefix.
            let chunk = slice.prefix(mtuPayload)
            reassembledBlob.append(chunk)
            offset += chunk.count
        }
        XCTAssertEqual(reassembledBlob, framed)

        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertEqual(try r.offer(reassembledBlob), payload)
    }

    /// An offset exactly at the end yields an empty final slice (the spec's
    /// "read complete" signal); slicing must not crash there.
    func testOffsetAtEndIsEmptySlice() throws {
        let framed = try UnifyNearbyFraming.frame("bitcoin:?lno=\(offer)")
        let end = framed.count
        let slice = framed.subdata(in: end..<framed.count)
        XCTAssertTrue(slice.isEmpty)
    }

    // MARK: - sanitizeAdvertisedName (mirror of Kotlin)

    func testSanitizePassesThroughShortName() {
        XCTAssertEqual(UnifyNearbyContract.sanitizeAdvertisedName("Vincenzo"), "Vincenzo")
    }

    func testSanitizeCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(UnifyNearbyContract.sanitizeAdvertisedName("  Sara   Lee \n"), "Sara Lee")
    }

    func testSanitizeReplacesControlChars() {
        XCTAssertEqual(UnifyNearbyContract.sanitizeAdvertisedName("Bob\u{0007}\u{0008}"), "Bob")
    }

    func testSanitizeBlankReturnsNil() {
        XCTAssertNil(UnifyNearbyContract.sanitizeAdvertisedName("   "))
        XCTAssertNil(UnifyNearbyContract.sanitizeAdvertisedName(""))
        XCTAssertNil(UnifyNearbyContract.sanitizeAdvertisedName(nil))
    }

    /// Oversized ASCII name truncated to exactly 20 bytes.
    func testSanitizeTruncatesOversizedAsciiName() {
        let long = String(repeating: "a", count: 40)
        let out = UnifyNearbyContract.sanitizeAdvertisedName(long)
        XCTAssertEqual(out?.utf8.count, UnifyNearbyContract.maxAdvertisedNameBytes)
        XCTAssertEqual(out, String(repeating: "a", count: 20))
    }

    /// Truncation must land on a UTF-8 codepoint boundary, never splitting a
    /// multi-byte character. "🚀" is 4 bytes; 5 of them = 20 bytes exactly, but
    /// the 6th would overflow, so we expect 4 rockets (16 bytes), not a split.
    func testSanitizeTruncatesOnUTF8Boundary() {
        let rockets = String(repeating: "🚀", count: 10) // 40 bytes
        let out = UnifyNearbyContract.sanitizeAdvertisedName(rockets)
        XCTAssertNotNil(out)
        // 20 / 4 = 5 whole rockets fit (20 bytes), boundary-safe.
        XCTAssertEqual(out, String(repeating: "🚀", count: 5))
        XCTAssertEqual(out?.utf8.count, 20)
    }

    /// A 3-byte codepoint that can't fit a whole unit at the boundary backs off.
    func testSanitizeBacksOffMidCodepoint() {
        // "é" via combining is messy; use a 3-byte char (e.g. "あ" = 3 bytes).
        // 6 × "あ" = 18 bytes (fits); a 7th would be 21 → back off to 6.
        let kana = String(repeating: "\u{3042}", count: 8) // 24 bytes
        let out = UnifyNearbyContract.sanitizeAdvertisedName(kana)
        XCTAssertEqual(out, String(repeating: "\u{3042}", count: 6))
        XCTAssertEqual(out?.utf8.count, 18)
    }

    // MARK: - Manufacturer-data 0xFFFF name parse (payer reads receiver name)

    #if canImport(CoreBluetooth)
    private func mfgData(companyLE: [UInt8], name: String) -> Data {
        var d = Data(companyLE)
        d.append(Data(name.utf8))
        return d
    }

    func testManufacturerNameValid() {
        let data = mfgData(companyLE: [0xFF, 0xFF], name: "Vincenzo")
        XCTAssertEqual(UnifyNearbyService.nameFromManufacturerData(data), "Vincenzo")
    }

    func testManufacturerNameWrongCompanyIgnored() {
        // Company id 0x004C (Apple) — not our 0xFFFF; ignore.
        let data = mfgData(companyLE: [0x4C, 0x00], name: "NotForUs")
        XCTAssertNil(UnifyNearbyService.nameFromManufacturerData(data))
    }

    func testManufacturerNameOversizedTruncatedOnBoundary() {
        // 10 rockets (40 bytes) under 0xFFFF → truncated to 5 (20 bytes).
        let data = mfgData(companyLE: [0xFF, 0xFF], name: String(repeating: "🚀", count: 10))
        XCTAssertEqual(UnifyNearbyService.nameFromManufacturerData(data), String(repeating: "🚀", count: 5))
    }

    func testManufacturerNameEmptyFallsBack() {
        // Only the company id, no name bytes → nil (caller falls back to default).
        let data = Data([0xFF, 0xFF])
        XCTAssertNil(UnifyNearbyService.nameFromManufacturerData(data))
        // Whitespace-only name also sanitizes to nil.
        let ws = mfgData(companyLE: [0xFF, 0xFF], name: "   ")
        XCTAssertNil(UnifyNearbyService.nameFromManufacturerData(ws))
    }

    // MARK: - advertisedName precedence (local name preferred, then mfg, then default)

    func testAdvertisedNamePrefersLocalName() {
        let adv: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "LocalNick",
            CBAdvertisementDataManufacturerDataKey: mfgData(companyLE: [0xFF, 0xFF], name: "MfgNick")
        ]
        XCTAssertEqual(UnifyNearbyService.advertisedName(adv, peripheralName: "DeviceName"), "LocalNick")
    }

    func testAdvertisedNameFallsBackToManufacturer() {
        let adv: [String: Any] = [
            CBAdvertisementDataManufacturerDataKey: mfgData(companyLE: [0xFF, 0xFF], name: "MfgNick")
        ]
        XCTAssertEqual(UnifyNearbyService.advertisedName(adv, peripheralName: "DeviceName"), "MfgNick")
    }

    func testAdvertisedNameFallsBackToPeripheralName() {
        // No local name, no manufacturer name → use the GAP peripheral name.
        XCTAssertEqual(UnifyNearbyService.advertisedName([:], peripheralName: "Vince iPhone"), "Vince iPhone")
    }

    func testAdvertisedNameDefaultWhenNothing() {
        XCTAssertEqual(
            UnifyNearbyService.advertisedName([:], peripheralName: nil),
            UnifyNearbyContract.advertisedNamePrefix
        )
    }
    #endif
}
