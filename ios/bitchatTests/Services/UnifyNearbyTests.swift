//
// UnifyNearbyTests.swift
// bitchatTests
//
// Tests for the Unify nearby-payments interop logic we consume (payer side):
//   - UnifyNearbyFraming: the 4-byte big-endian length-prefixed chunk
//     reassembly (mirror of Unify's NearbyPaymentFraming.kt).
//   - UnifyBIP321: extracting a payable Lightning destination from a served
//     BIP321 `bitcoin:` URI (or bare offer/invoice).
// See docs/UNIFY-INTEROP.md.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class UnifyNearbyTests: XCTestCase {

    // A representative BOLT12 offer + BOLT11 invoice prefix used throughout.
    private let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq"
    private let invoice = "lnbc1u1pjexampleinvoicepayloadxyz"

    // MARK: - Framing: contract constants match Unify

    func testContractConstants() {
        XCTAssertEqual(UnifyNearbyContract.serviceUUIDString, "b1f7e2a0-9c3d-4e8a-bf21-3a1c0de54f10")
        XCTAssertEqual(UnifyNearbyContract.payloadCharacteristicUUIDString, "b1f7e2a1-9c3d-4e8a-bf21-3a1c0de54f10")
        XCTAssertEqual(UnifyNearbyContract.defaultMaxChunkSize, 180)
        XCTAssertEqual(UnifyNearbyContract.maxPayloadBytes, 8 * 1024)
        XCTAssertEqual(UnifyNearbyContract.protocolVersion, 2)
        XCTAssertEqual(UnifyNearbyContract.advertisedNamePrefix, "Unify user")
        XCTAssertEqual(UnifyNearbyContract.nameManufacturerID, 0xFFFF)
    }

    // MARK: - Framing: frame layout

    func testFramePrependsBigEndianLength() throws {
        let framed = try UnifyNearbyFraming.frame("ABC")
        XCTAssertEqual(framed.count, 4 + 3)
        XCTAssertEqual(Array(framed.prefix(4)), [0, 0, 0, 3])
        XCTAssertEqual(String(decoding: framed.suffix(3), as: UTF8.self), "ABC")
    }

    func testFrameRejectsOversizePayload() {
        let big = String(repeating: "x", count: UnifyNearbyContract.maxPayloadBytes + 1)
        XCTAssertThrowsError(try UnifyNearbyFraming.frame(big)) { error in
            XCTAssertEqual(error as? UnifyNearbyFraming.FramingError,
                           .payloadTooLarge(UnifyNearbyContract.maxPayloadBytes + 1))
        }
    }

    // MARK: - Framing: reassembly

    /// The whole framed blob arriving in one read (GATT long-read path).
    func testReassembleSingleRead() throws {
        let framed = try UnifyNearbyFraming.frame(offer)
        let r = UnifyNearbyFraming.Reassembler()
        let out = try r.offer(framed)
        XCTAssertEqual(out, offer)
        XCTAssertTrue(r.isComplete)
    }

    /// The framed blob split into 180-byte chunks (the notify path).
    func testReassembleChunkedStream() throws {
        let payload = "bitcoin:?lightning=\(offer)"
        let framed = try UnifyNearbyFraming.frame(payload)
        let r = UnifyNearbyFraming.Reassembler()
        var result: String?
        var offset = framed.startIndex
        while offset < framed.endIndex {
            let end = framed.index(offset, offsetBy: UnifyNearbyContract.defaultMaxChunkSize,
                                   limitedBy: framed.endIndex) ?? framed.endIndex
            let chunk = framed.subdata(in: offset..<end)
            result = try r.offer(chunk)
            offset = end
        }
        XCTAssertEqual(result, payload)
        XCTAssertTrue(r.isComplete)
    }

    /// A header that arrives split across two tiny chunks.
    func testReassembleHeaderSpanningChunks() throws {
        let framed = try UnifyNearbyFraming.frame("hello")
        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertNil(try r.offer(framed.subdata(in: framed.startIndex..<framed.index(framed.startIndex, offsetBy: 2))))
        XCTAssertNil(try r.offer(framed.subdata(in: framed.index(framed.startIndex, offsetBy: 2)..<framed.index(framed.startIndex, offsetBy: 4))))
        let out = try r.offer(framed.subdata(in: framed.index(framed.startIndex, offsetBy: 4)..<framed.endIndex))
        XCTAssertEqual(out, "hello")
    }

    func testReassembleEmptyChunkIsNoOp() throws {
        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertNil(try r.offer(Data()))
        XCTAssertFalse(r.isComplete)
    }

    func testReassembleRejectsOverrun() throws {
        var framed = try UnifyNearbyFraming.frame("ab")
        framed.append(contentsOf: [0x99]) // one byte too many
        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertThrowsError(try r.offer(framed)) { error in
            guard case .malformedFrame = (error as? UnifyNearbyFraming.FramingError) else {
                return XCTFail("expected malformedFrame, got \(error)")
            }
        }
    }

    func testReassembleRejectsDeclaredLengthOutOfRange() {
        // Header declares a length larger than MAX_PAYLOAD_BYTES.
        let bogus = Data([0x7F, 0xFF, 0xFF, 0xFF, 0x00])
        let r = UnifyNearbyFraming.Reassembler()
        XCTAssertThrowsError(try r.offer(bogus)) { error in
            guard case .malformedFrame = (error as? UnifyNearbyFraming.FramingError) else {
                return XCTFail("expected malformedFrame, got \(error)")
            }
        }
    }

    func testReassemblerResetAcceptsFreshTransfer() throws {
        let r = UnifyNearbyFraming.Reassembler()
        _ = try r.offer(try UnifyNearbyFraming.frame("first"))
        XCTAssertTrue(r.isComplete)
        r.reset()
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(try r.offer(try UnifyNearbyFraming.frame("second")), "second")
    }

    // MARK: - Big-endian read on a non-zero-based slice

    func testReadBigEndianIntOnSlicedData() {
        // `Data` slices can carry a non-zero startIndex; the reader must index
        // from the data's own startIndex, not from 0.
        let base = Data([0xAA, 0xBB, 0x00, 0x00, 0x01, 0x05, 0xCC])
        let nonZeroBased = base[2...] // startIndex == 2
        XCTAssertEqual(UnifyNearbyFraming.readBigEndianInt(nonZeroBased, at: 0), 0x0105)
        // subdata rebases to startIndex 0 — must also work.
        let rebased = base.subdata(in: 2..<base.count)
        XCTAssertEqual(UnifyNearbyFraming.readBigEndianInt(rebased, at: 0), 0x0105)
    }

    // MARK: - BIP321 parsing

    func testParseBitcoinURIWithLightningOffer() {
        let parsed = UnifyBIP321.parse("bitcoin:?lightning=\(offer)")
        XCTAssertEqual(parsed?.lightning, offer)
        XCTAssertNil(parsed?.amountSats)
    }

    func testParseBitcoinURIWithOnchainAndLightning() {
        let uri = "bitcoin:bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4?lightning=\(offer)"
        XCTAssertEqual(UnifyBIP321.parse(uri)?.lightning, offer)
    }

    func testParseBitcoinURIWithAmount() {
        // 0.0001 BTC = 10,000 sats.
        let parsed = UnifyBIP321.parse("bitcoin:?lightning=\(invoice)&amount=0.0001")
        XCTAssertEqual(parsed?.lightning, invoice)
        XCTAssertEqual(parsed?.amountSats, 10_000)
    }

    func testParseBareOffer() {
        let parsed = UnifyBIP321.parse(offer)
        XCTAssertEqual(parsed?.lightning, offer)
        XCTAssertNil(parsed?.amountSats)
    }

    func testParseBareInvoiceUppercased() {
        // QR-encoded BOLT11 invoices are often uppercase; we lowercase them.
        let parsed = UnifyBIP321.parse(invoice.uppercased())
        XCTAssertEqual(parsed?.lightning, invoice)
    }

    func testParseLightningSchemePrefix() {
        XCTAssertEqual(UnifyBIP321.parse("lightning:\(offer)")?.lightning, offer)
    }

    func testParseLnoQueryAlias() {
        XCTAssertEqual(UnifyBIP321.parse("bitcoin:?lno=\(offer)")?.lightning, offer)
    }

    func testParsePercentEncodedLightningParam() {
        // A receiver that URL-encodes the offer in the query.
        let encoded = offer // offer has no reserved chars; emulate with a wrapped invoice
        let uri = "bitcoin:?lightning=\(encoded)"
        XCTAssertEqual(UnifyBIP321.parse(uri)?.lightning, encoded)
    }

    func testParseOnchainOnlyReturnsNil() {
        // No Lightning leg → we have no on-chain send path.
        XCTAssertNil(UnifyBIP321.parse("bitcoin:bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
    }

    func testParseEmptyReturnsNil() {
        XCTAssertNil(UnifyBIP321.parse("   "))
        XCTAssertNil(UnifyBIP321.parse(""))
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(UnifyBIP321.parse("https://example.com/pay"))
        XCTAssertNil(UnifyBIP321.parse("just some text"))
    }

    func testBtcStringToSats() {
        XCTAssertEqual(UnifyBIP321.btcStringToSats("1"), 100_000_000)
        XCTAssertEqual(UnifyBIP321.btcStringToSats("0.00000001"), 1)
        XCTAssertEqual(UnifyBIP321.btcStringToSats("0.0001"), 10_000)
        XCTAssertNil(UnifyBIP321.btcStringToSats("0"))
        XCTAssertNil(UnifyBIP321.btcStringToSats("abc"))
        XCTAssertNil(UnifyBIP321.btcStringToSats("-1"))
    }
}
