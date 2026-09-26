//
// SonarHandleAddressTests.swift
// bitchatTests
//
// Which wallet the public handle (name@sonarprivacy.xyz) pays. A user who
// claimed the handle on the Breez wallet and updates the app must not find
// it silently pointed at the Cashu mint: the app re-registers it with the
// Cashu offer only when it already pays Cashu, or when no old wallet exists
// here; otherwise it shows "still pays your old wallet" and moves it only on
// a confirmed Move. Compose mirror: HandleAddressTest + WalletAppStateTest.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import XCTest
@testable import Sonar

/// A ready wallet whose published offer the test changes.
private final class OfferWallet: SonarWalletProviding {
    let offer: CurrentValueSubject<String?, Never>

    init(offer: String?) { self.offer = CurrentValueSubject(offer) }

    var state: SonarWalletState { .ready(balanceSats: 0) }
    var statePublisher: AnyPublisher<SonarWalletState, Never> { Just(state).eraseToAnyPublisher() }
    var cachedReceiveOffer: String? { offer.value }
    var receiveOfferPublisher: AnyPublisher<String?, Never> { offer.eraseToAnyPublisher() }

    func send(destination: String, amountSats: Int64, note: String?, feeFromAmount: Bool) async throws -> SonarWalletPayment {
        throw UnconfiguredWallet.WalletError.notConfigured
    }

    func createOffer() async throws -> String {
        guard let value = offer.value else { throw UnconfiguredWallet.WalletError.notConfigured }
        return value
    }
}

private struct RegistrarDown: Error {}

@MainActor
final class SonarHandleAddressTests: XCTestCase {

    // MARK: The decision (pure)

    func testHandleOfferActionMatrix() {
        typealias P = SonarHandleOfferPolicy
        let handle = "alice@sonarprivacy.xyz"
        let cashu = "lno1cashu"
        // No claimed handle: nothing, whatever else holds.
        for presence: SonarLegacyPresence in [.present, .absent, .unknown] {
            for wallet: SonarHandleAddressWallet? in [nil, .legacy, .cashu] {
                XCTAssertEqual(P.action(claimedHandle: nil, legacyPresence: presence, addressWallet: wallet,
                                        cashuOffer: cashu, lastRegisteredOffer: nil), .none)
                XCTAssertEqual(P.action(claimedHandle: "  ", legacyPresence: presence, addressWallet: wallet,
                                        cashuOffer: cashu, lastRegisteredOffer: nil), .none)
            }
        }

        // The upgrade: a handle claimed on the Breez wallet (nothing recorded)
        // while that wallet is still here is NEVER re-registered on its own.
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .present, addressWallet: nil,
                                cashuOffer: cashu, lastRegisteredOffer: nil), .askToMove)
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .present, addressWallet: .legacy,
                                cashuOffer: cashu, lastRegisteredOffer: "lno1breez"), .askToMove)
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .present, addressWallet: nil,
                                cashuOffer: nil, lastRegisteredOffer: nil), .askToMove, "the notice needs no Cashu offer")
        // Presence not established yet: wait (never treat unknown as absent).
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .unknown, addressWallet: nil,
                                cashuOffer: cashu, lastRegisteredOffer: nil), .none)
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .unknown, addressWallet: .legacy,
                                cashuOffer: cashu, lastRegisteredOffer: nil), .none)
        // No old wallet here: nothing to move away from.
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .absent, addressWallet: nil,
                                cashuOffer: cashu, lastRegisteredOffer: nil), .reclaimWithCashu)
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .absent, addressWallet: .legacy,
                                cashuOffer: cashu, lastRegisteredOffer: "lno1breez"), .reclaimWithCashu)
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .absent, addressWallet: nil,
                                cashuOffer: nil, lastRegisteredOffer: nil), .none, "no offer, nothing to register")
        // Already paying Cashu: follow the offer, once per offer.
        for presence: SonarLegacyPresence in [.present, .absent, .unknown] {
            XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: presence, addressWallet: .cashu,
                                    cashuOffer: cashu, lastRegisteredOffer: nil), .reclaimWithCashu, "chat-only claim upgrade")
            XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: presence, addressWallet: .cashu,
                                    cashuOffer: "lno1rotated", lastRegisteredOffer: cashu), .reclaimWithCashu, "rotated offer")
            XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: presence, addressWallet: .cashu,
                                    cashuOffer: cashu, lastRegisteredOffer: cashu), .none, "already registered")
            XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: presence, addressWallet: .cashu,
                                    cashuOffer: nil, lastRegisteredOffer: cashu), .none)
        }
        XCTAssertEqual(P.action(claimedHandle: handle, legacyPresence: .absent, addressWallet: .legacy,
                                cashuOffer: cashu, lastRegisteredOffer: cashu), .none)
    }

    func testMoveBackIsOfferedOnlyWhileTheHandlePaysCashuAndTheOldWalletIsHere() {
        typealias P = SonarHandleOfferPolicy
        let handle = "alice@sonarprivacy.xyz"
        XCTAssertTrue(P.canMoveBack(claimedHandle: handle, legacyPresence: .present, addressWallet: .cashu))
        XCTAssertFalse(P.canMoveBack(claimedHandle: handle, legacyPresence: .absent, addressWallet: .cashu))
        XCTAssertFalse(P.canMoveBack(claimedHandle: handle, legacyPresence: .unknown, addressWallet: .cashu))
        XCTAssertFalse(P.canMoveBack(claimedHandle: handle, legacyPresence: .present, addressWallet: .legacy))
        XCTAssertFalse(P.canMoveBack(claimedHandle: handle, legacyPresence: .present, addressWallet: nil))
        XCTAssertFalse(P.canMoveBack(claimedHandle: nil, legacyPresence: .present, addressWallet: .cashu))
    }

    func testTheRecordIsPerAccountAndSurvivesAReload() {
        let suite = "SonarHandleAddressTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SonarHandleAddressRecord.load(defaults: defaults, account: "npub1a"),
                       SonarHandleAddressRecord(wallet: nil, registeredOffer: nil))
        SonarHandleAddressRecord(wallet: .cashu, registeredOffer: "lno1x").save(defaults: defaults, account: "npub1a")
        SonarHandleAddressRecord(wallet: .legacy, registeredOffer: "lno1breez").save(defaults: defaults, account: "npub1b")
        XCTAssertEqual(SonarHandleAddressRecord.load(defaults: defaults, account: "npub1a"),
                       SonarHandleAddressRecord(wallet: .cashu, registeredOffer: "lno1x"))
        XCTAssertEqual(SonarHandleAddressRecord.load(defaults: defaults, account: "npub1b"),
                       SonarHandleAddressRecord(wallet: .legacy, registeredOffer: "lno1breez"))
        SonarHandleAddressRecord.removeAll(defaults: defaults)
        XCTAssertEqual(SonarHandleAddressRecord.load(defaults: defaults, account: "npub1a"),
                       SonarHandleAddressRecord(wallet: nil, registeredOffer: nil))
    }

    // MARK: The store's real call sites

    private struct Claim: Equatable {
        let name: String
        let offer: String?
    }

    /// A store with a claimed handle and a known account, its registrar
    /// captured. `presence` pins the legacy wallet (the real one opens Breez).
    private func makeStore(
        presence: SonarLegacyPresence,
        offer: String = "lno1cashu",
        registrarFails: @escaping () -> Bool = { false }
    ) async throws -> (store: SonarAppStore, wallet: OfferWallet, claims: () -> [Claim], cleanup: () -> Void) {
        let wallet = OfferWallet(offer: offer)
        let (store, cleanupStore) = makeIsolatedSonarAppStore(wallet: wallet)
        var claims: [Claim] = []
        store.registerHandleAtRegistrar = { name, offer in
            claims.append(Claim(name: name, offer: offer))
            if registrarFails() { throw RegistrarDown() }
            return "\(name)@\(SonarAppStore.handleDomain)"
        }
        store.legacyPresenceOverrideForTesting = presence
        let account = "npub1handletest\(UUID().uuidString.lowercased())"
        store.marmot.npub = account
        try await waitUntil("account known") { store.handleAddressAccountForTesting == account }
        store.seedClaimedHandleForTesting("alice@\(SonarAppStore.handleDomain)")
        let cleanup = {
            UserDefaults.standard.removeObject(forKey: SonarHandleAddressRecord.walletKeyPrefix + account)
            UserDefaults.standard.removeObject(forKey: SonarHandleAddressRecord.offerKeyPrefix + account)
            cleanupStore()
        }
        return (store, wallet, { claims }, cleanup)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(done(), "timed out waiting for: \(what)")
    }

    /// The reported scenario: an address claimed on the Breez wallet, which
    /// is still here. Publishing the Cashu offer (first load, then a rotated
    /// offer) must not re-register the handle; the notice says where it
    /// pays; the confirmed Move registers the Cashu offer and records it.
    func testAnAddressOnTheOldWalletMovesOnlyOnAConfirmedMove() async throws {
        let (store, wallet, claims, cleanup) = try await makeStore(presence: .present)
        defer { cleanup() }

        // The descriptor publish path runs on every offer change.
        wallet.offer.send("lno1cashurotated")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(claims(), [], "the handle must not be re-registered with the Cashu offer without consent")
        XCTAssertEqual(store.handleAddressNotice, .paysOldWallet(address: "alice@\(SonarAppStore.handleDomain)"))
        XCTAssertNil(store.handleAddressWallet)
        XCTAssertFalse(store.canMoveHandleBackToOldWallet)

        store.moveHandleToNewWallet()
        try await waitUntil("the move registered") { store.handleAddressWallet == .cashu }
        XCTAssertEqual(claims(), [Claim(name: "alice", offer: "lno1cashurotated")])
        XCTAssertEqual(store.handleMoveState, .idle)
        XCTAssertEqual(store.handleAddressNotice, .none)
        XCTAssertTrue(store.canMoveHandleBackToOldWallet, "the old wallet is still here: offer the way back")

        // From now on the handle follows the Cashu offer, once per offer.
        wallet.offer.send("lno1cashuthird")
        try await waitUntil("the rotated offer registered") { claims().count == 2 }
        XCTAssertEqual(claims().last, Claim(name: "alice", offer: "lno1cashuthird"))
        wallet.offer.send("lno1cashuthird")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(claims().count, 2, "an unchanged offer is not registered again")
    }

    /// Positive control for the test above: with no old wallet here the same
    /// path DOES register the Cashu offer (nothing to move away from), so its
    /// silence is the decision, not a dead path.
    func testWithNoOldWalletTheHandleFollowsTheCashuOffer() async throws {
        let (store, _, claims, cleanup) = try await makeStore(presence: .absent)
        defer { cleanup() }
        try await waitUntil("re-registered") { store.handleAddressWallet == .cashu }
        XCTAssertEqual(claims(), [Claim(name: "alice", offer: "lno1cashu")])
        XCTAssertEqual(store.handleAddressNotice, .none)
    }

    /// Unknown presence is never "absent": nothing moves, nothing is shown.
    func testUnknownPresenceMovesNothing() async throws {
        let (store, wallet, claims, cleanup) = try await makeStore(presence: .unknown)
        defer { cleanup() }
        wallet.offer.send("lno1cashurotated")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(claims(), [])
        XCTAssertEqual(store.handleAddressNotice, .none)
    }

    /// A failed Move leaves the address where it was, and says so.
    func testAFailedMoveLeavesTheAddressOnTheOldWallet() async throws {
        let (store, _, claims, cleanup) = try await makeStore(presence: .present, registrarFails: { true })
        defer { cleanup() }
        store.moveHandleToNewWallet()
        try await waitUntil("the move failed") {
            if case .failed = store.handleMoveState { return true }
            return false
        }
        XCTAssertEqual(claims().count, 1)
        XCTAssertNil(store.handleAddressWallet)
        XCTAssertEqual(store.handleAddressNotice, .paysOldWallet(address: "alice@\(SonarAppStore.handleDomain)"))
        store.resetHandleMoveState()
        XCTAssertEqual(store.handleMoveState, .idle)
    }

    /// A failed automatic re-registration is surfaced, not silently dropped.
    func testAFailedAutomaticUpdateIsSurfaced() async throws {
        let (store, _, claims, cleanup) = try await makeStore(presence: .absent, registrarFails: { true })
        defer { cleanup() }
        try await waitUntil("the update failure is shown") {
            store.handleAddressNotice == .updateFailing(address: "alice@\(SonarAppStore.handleDomain)")
        }
        XCTAssertEqual(claims().count, 1, "retried with backoff, not in a tight loop")
        XCTAssertNil(store.handleAddressWallet)
    }

    /// The way back needs the old wallet itself (its own offer): without it
    /// connected nothing is registered and the reason is shown.
    func testMovingBackNeedsTheOldWalletConnected() async throws {
        let (store, _, claims, cleanup) = try await makeStore(presence: .present)
        defer { cleanup() }
        store.moveHandleToNewWallet()
        try await waitUntil("moved") { store.handleAddressWallet == .cashu }
        XCTAssertTrue(store.canMoveHandleBackToOldWallet)

        store.moveHandleToOldWallet()
        try await waitUntil("refused") {
            if case .failed = store.handleMoveState { return true }
            return false
        }
        XCTAssertEqual(claims().count, 1, "no registration without the old wallet's own offer")
        XCTAssertEqual(store.handleAddressWallet, .cashu)
    }
}
