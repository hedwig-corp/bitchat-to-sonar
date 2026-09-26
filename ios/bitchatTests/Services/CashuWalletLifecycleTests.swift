//
// CashuWalletLifecycleTests.swift
// bitchatTests
//
// The wallet seam and its lifecycle call sites: `SonarAppStore.makeWallet`
// is Cashu, the store layout and account id match every host, account
// replacement KEEPS the old account's Cashu store, and panic wipe removes
// every Cashu root.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SonarCore
import XCTest
@testable import Sonar

@MainActor
final class CashuWalletLifecycleTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = try CashuTestFixtures.tempDirectory("lifecycle")
        (defaults, suite) = CashuTestFixtures.defaults()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suite)
    }

    /// The store's production seam builds the Cashu wallet — not Breez.
    func testMakeWalletReturnsTheCashuWallet() {
        let wallet = SonarAppStore.makeWallet(keychain: MockKeychain())
        XCTAssertTrue(wallet is CashuWallet, "primary wallet must be Cashu, got \(type(of: wallet))")
        XCTAssertFalse(wallet is LegacyBreezWallet)
        XCTAssertEqual(wallet.custodyDescription, "Held as ecash at mint.hedwig.sh")
    }

    /// `<root>/sonar-cashu/<sha256(nsec)[:16] hex>/mainnet` — must match the
    /// other hosts byte for byte (vectors computed outside Swift).
    func testAccountIdAndStoreLayoutMatchTheOtherHosts() {
        XCTAssertEqual(SonarCashuStorage.accountId(nsec: CashuTestFixtures.nsecA), CashuTestFixtures.accountIdA)
        XCTAssertEqual(SonarCashuStorage.accountId(nsec: CashuTestFixtures.nsecB), CashuTestFixtures.accountIdB)
        let dir = SonarCashuStorage.workingDirectory(in: URL(fileURLWithPath: "/root"), accountId: "abc")
        XCTAssertEqual(dir.path, "/root/sonar-cashu/abc/mainnet")
        XCTAssertEqual(SonarCashuStorage.mintURL, "https://mint.hedwig.sh")
    }

    /// The FFI working dir handed to the native constructor is the per-account
    /// path under the injected root (Application Support in production).
    func testOpenHandsTheNativeThePerAccountWorkingDirectory() async throws {
        let native = FakeCashuNative()
        var seen: (nsec: String, mint: String, dir: String)?
        let root: URL = base
        let service = CashuWalletService(
            makeNative: { nsec, mint, dir in
                seen = (nsec, mint, dir)
                return native
            },
            defaults: defaults,
            storageBase: { root },
            retryDelaysNanos: [30_000_000]
        )
        await service.open(nsec: CashuTestFixtures.nsecA)
        let expected = SonarCashuStorage.workingDirectory(in: base, accountId: CashuTestFixtures.accountIdA)
        XCTAssertEqual(seen?.dir, expected.path)
        XCTAssertEqual(seen?.nsec, CashuTestFixtures.nsecA)
        XCTAssertEqual(seen?.mint, "https://mint.hedwig.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        try? await service.release()
    }

    /// Account replacement (the call `SonarAppStore.restoreAccount` makes):
    /// the old account's `sonar-cashu/<old>/` stays on disk untouched — it
    /// may hold funds — and the new account gets its own directory.
    func testIdentityReplacementKeepsTheOldAccountsCashuStore() async throws {
        let native = FakeCashuNative()
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data(CashuTestFixtures.nsecA.utf8), forKey: SonarAccountKeyExport.marmotNsecKey)
        let wallet = CashuWallet(keychain: keychain, service: service)

        wallet.start()
        await waitUntil { service.connectivity == .online }
        let oldDir = SonarCashuStorage.workingDirectory(in: base, accountId: CashuTestFixtures.accountIdA)
        let proofs = oldDir.appendingPathComponent("wallet.redb")
        try Data("proofs".utf8).write(to: proofs)

        try await wallet.prepareForIdentityReplacement()

        XCTAssertTrue(FileManager.default.fileExists(atPath: proofs.path), "old account's store must survive replacement")
        XCTAssertEqual(native.count("wipeLocalStorage"), 0, "replacement never wipes a Cashu store")
        XCTAssertGreaterThanOrEqual(native.count("disconnect"), 1, "the old wallet is disconnected")
        XCTAssertNil(service.accountId)
        XCTAssertEqual(wallet.state, .notConfigured)

        // The restored account opens its own store; the old one is still there.
        _ = keychain.saveIdentityKey(Data(CashuTestFixtures.nsecB.utf8), forKey: SonarAccountKeyExport.marmotNsecKey)
        wallet.start()
        await waitUntil { service.accountId == CashuTestFixtures.accountIdB && service.isOpen }
        let newDir = SonarCashuStorage.workingDirectory(in: base, accountId: CashuTestFixtures.accountIdB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: proofs.path))
        try? await service.release()
    }

    /// Replacement refuses while a payment is in flight instead of tearing it
    /// down (the FFI forbids disconnect under a running send).
    func testIdentityReplacementRefusesWhileASendIsInFlight() async throws {
        let native = BlockingSendNative()
        native.confirmedSats = 10_000
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }

        let send = Task { try await service.send(destination: "lno1peer", amountSats: 10, note: "", feeFromAmount: false, maxFeeSats: nil) }
        await waitUntil { native.sendStarted }
        do {
            try await service.release()
            XCTFail("release must refuse while a send is in flight")
        } catch let error as CashuWalletError {
            XCTAssertEqual(error, .paymentInFlight)
        }
        native.unblock()
        _ = try await send.value
        try await service.release()
    }

    /// Panic wipe (the call `SonarAppStore.performWipe` makes): disconnect
    /// first, then EVERY `sonar-cashu/` root — the open account's and any
    /// kept from earlier replacements — and every cached balance/offer.
    func testPanicWipeRemovesEveryCashuRoot() async throws {
        let native = FakeCashuNative()
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data(CashuTestFixtures.nsecA.utf8), forKey: SonarAccountKeyExport.marmotNsecKey)
        let wallet = CashuWallet(keychain: keychain, service: service)

        // A store kept from an earlier account replacement.
        let keptDir = SonarCashuStorage.workingDirectory(in: base, accountId: CashuTestFixtures.accountIdB)
        try FileManager.default.createDirectory(at: keptDir, withIntermediateDirectories: true)
        try Data("old-proofs".utf8).write(to: keptDir.appendingPathComponent("wallet.redb"))
        defaults.set("lno1old", forKey: CashuWalletService.offerKey(CashuTestFixtures.accountIdB))

        wallet.start()
        await waitUntil { service.connectivity == .online }
        XCTAssertNotNil(defaults.string(forKey: CashuWalletService.offerKey(CashuTestFixtures.accountIdA)))

        let wiped = await wallet.wipeForEmergency()

        XCTAssertTrue(wiped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SonarCashuStorage.root(in: base).path))
        XCTAssertNil(defaults.string(forKey: CashuWalletService.offerKey(CashuTestFixtures.accountIdA)))
        XCTAssertNil(defaults.string(forKey: CashuWalletService.offerKey(CashuTestFixtures.accountIdB)))
        XCTAssertNil(defaults.object(forKey: CashuWalletService.balanceKey(CashuTestFixtures.accountIdA)))
        let names = native.calls.map(\.name)
        let disconnectAt = try XCTUnwrap(names.lastIndex(of: "disconnect"))
        let wipeAt = try XCTUnwrap(names.lastIndex(of: "wipeLocalStorage"))
        XCTAssertLessThan(disconnectAt, wipeAt, "disconnect before wiping the store")
        XCTAssertEqual(wallet.state, .notConfigured)
    }
}

/// A fake whose `send` blocks until released, to hold a payment in flight.
private final class BlockingSendNative: FakeCashuNative, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let flagLock = NSLock()
    private var _sendStarted = false

    var sendStarted: Bool {
        flagLock.lock(); defer { flagLock.unlock() }
        return _sendStarted
    }

    func unblock() { gate.signal() }

    override func send(prepared: WalletPreparedSend, note: String) throws -> WalletPayment {
        flagLock.lock(); _sendStarted = true; flagLock.unlock()
        gate.wait()
        return try super.send(prepared: prepared, note: note)
    }
}
