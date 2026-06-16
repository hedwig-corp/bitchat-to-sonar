//
// SonarWalletDerivationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

/// The Lightning wallet entropy is derived deterministically from the chat
/// identity's Nostr secret (one identity = one wallet, reconstructable from the
/// nsec). These tests pin that determinism and the domain separation.
final class SonarWalletDerivationTests: XCTestCase {

    private let secretA = Data((0..<32).map { UInt8($0) })          // 00,01,...,1f
    private let secretB = Data((0..<32).map { UInt8(255 - $0) })    // ff,fe,...,e0

    func testSameSecretYieldsSameEntropy() {
        let e1 = SonarWalletDerivation.entropyHex(fromSecret: secretA)
        let e2 = SonarWalletDerivation.entropyHex(fromSecret: secretA)
        XCTAssertEqual(e1, e2, "derivation must be deterministic")
        XCTAssertEqual(e1.count, 64, "32 bytes => 64 hex chars")
    }

    func testDifferentSecretsYieldDifferentEntropy() {
        XCTAssertNotEqual(
            SonarWalletDerivation.entropyHex(fromSecret: secretA),
            SonarWalletDerivation.entropyHex(fromSecret: secretB)
        )
    }

    func testEntropyIsNotTheRawSecret() {
        // Domain separation: the wallet seed must not be the signing key itself.
        let rawHex = secretA.map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(SonarWalletDerivation.entropyHex(fromSecret: secretA), rawHex)
    }

    func testDerivationIsStableAcrossRuns() {
        let hex = SonarWalletDerivation.entropyHex(fromSecret: secretA)
        XCTAssertEqual(hex, "801a82b16248f5c4c6363cae5ab6b9aff24724cb696ed41d936e53687c282806")
    }

    func testNsecRoundTripFeedsDerivation() throws {
        // A 32-byte secret encoded as nsec decodes back to the same secret,
        // so deriving from the nsec == deriving from the secret.
        let nsec = try Bech32.encode(hrp: "nsec", data: secretA)
        let recovered = SonarWalletDerivation.secret(fromNsec: nsec)
        XCTAssertEqual(recovered, secretA)
        XCTAssertEqual(
            SonarWalletDerivation.entropyHex(fromSecret: secretA),
            recovered.map { SonarWalletDerivation.entropyHex(fromSecret: $0) }
        )
    }

    func testRejectsNonNsec() {
        // An npub-hrp string must not be accepted as a wallet secret source.
        let npub = try? Bech32.encode(hrp: "npub", data: secretA)
        XCTAssertNotNil(npub)
        XCTAssertNil(SonarWalletDerivation.secret(fromNsec: npub!))
        XCTAssertNil(SonarWalletDerivation.secret(fromNsec: "not-a-key"))
    }
}
