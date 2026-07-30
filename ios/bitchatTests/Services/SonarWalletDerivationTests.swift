//
// SonarWalletDerivationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import WalletKit
@testable import Sonar

/// The Lightning wallet entropy is derived deterministically from the chat
/// identity's Nostr secret (one identity = one wallet, reconstructable from the
/// nsec). These tests pin that determinism and the domain separation.
@MainActor
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

    func testWalletStorageWipeRemovesSharedAndLegacyState() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let group = root.appendingPathComponent("group", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let sharedWallet = group.appendingPathComponent("breez-sdk/mainnet", isDirectory: true)
        let legacyWallet = support.appendingPathComponent("sonar-wallet", isDirectory: true)
        try fm.createDirectory(at: sharedWallet, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyWallet, withIntermediateDirectories: true)
        try Data("old-shared-wallet".utf8).write(to: sharedWallet.appendingPathComponent("wallet.db"))
        try Data("old-legacy-wallet".utf8).write(to: legacyWallet.appendingPathComponent("wallet.db"))

        let suite = "SonarWalletDerivationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("test-api-key", forKey: "breez_api_key")
        defaults.set("test-seed", forKey: "breez_seed_hex")
        defaults.set(true, forKey: "breez_mainnet")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }

        try BridgedWallet.wipeWalletFilesAndDefaults(
            fileManager: fm,
            appGroupContainer: group,
            applicationSupportDirectory: support,
            sharedDefaults: defaults
        )

        XCTAssertFalse(fm.fileExists(atPath: group.appendingPathComponent("breez-sdk").path))
        XCTAssertFalse(fm.fileExists(atPath: legacyWallet.path))
        XCTAssertNil(defaults.object(forKey: "breez_api_key"))
        XCTAssertNil(defaults.object(forKey: "breez_seed_hex"))
        XCTAssertNil(defaults.object(forKey: "breez_mainnet"))
    }

    func testWalletSeedStorageIsDurable() throws {
        let storage = KeychainWalletStorage()
        let key = "pr268-wallet-seed-\(UUID().uuidString)"
        let seed = Data((0..<32).map(UInt8.init))
        defer { storage.remove(key) }

        // This exercises the REAL keychain on purpose — a durability test that
        // swaps in a mock store proves nothing. But an unsigned simulator build
        // has no keychain entitlement, so every write fails with `-34018` and
        // the test reports a product failure that is really a missing
        // capability. Probe first and say so, rather than assert into a
        // keychain that cannot exist.
        //
        // The skip is deliberately narrow: it fires only when the very first
        // write fails, so a signed build (local dev, or CI once the test job is
        // signed) still runs the assertions below in full.
        let probeKey = "pr268-keychain-probe-\(UUID().uuidString)"
        defer { storage.remove(probeKey) }
        guard storage.putData(probeKey, Data([0x01])) else {
            throw XCTSkip(
                "Keychain is unavailable in this build (unsigned simulator builds "
                + "hit errSecMissingEntitlement / -34018). Run on a signed build to "
                + "cover wallet-seed durability."
            )
        }

        XCTAssertTrue(storage.putData(key, seed))
        XCTAssertEqual(storage.getData(key), seed)
    }
}
