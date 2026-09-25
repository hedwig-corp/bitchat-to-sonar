//
// CashuOfferBackupTests.swift
// bitchatTests
//
// The receive offer's quote id lived only on the device, so a reinstall
// published a NEW offer and payments to the old one stayed at the mint. The
// service backs the offer up to the account's relays and, on a fresh store,
// brings it back before it would create a new one.
//

import Foundation
import SonarCore
import XCTest
@testable import Sonar

/// The account's relays for offer backups; `answering = false` = unreachable.
@MainActor
private final class FakeBackupRelay: SonarOfferBackupRelay {
    var stored: [String]
    var answering = true
    private(set) var published: [String] = []

    init(stored: [String] = []) {
        self.stored = stored
    }

    func fetch() async -> [String]? {
        answering ? stored : nil
    }

    func publish(_ backup: String) async -> Bool {
        guard answering else { return false }
        published.append(backup)
        if !stored.contains(backup) { stored.append(backup) }
        return true
    }
}

@MainActor
final class CashuOfferBackupTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        base = try CashuTestFixtures.tempDirectory("offer-backup")
        (defaults, suite) = CashuTestFixtures.defaults()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suite)
    }

    private func service(_ native: FakeCashuNative, _ relay: FakeBackupRelay) -> CashuWalletService {
        let service = CashuTestFixtures.service(native: native, base: base, defaults: defaults)
        service.offerBackups = relay
        service.backupRetryNanos = 50_000_000
        return service
    }

    func testAReinstalledWalletPublishesItsBackedUpOfferNotANewOne() async {
        let native = FakeCashuNative()
        native.offer = nil
        native.createsOffer = "lno1new"
        let relay = FakeBackupRelay(stored: [FakeCashuNative.backup(of: "lno1old")])
        let service = service(native, relay)

        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.receiveOffer == "lno1old" }

        XCTAssertEqual(native.restoredBackups, [[FakeCashuNative.backup(of: "lno1old")]])
        XCTAssertEqual(relay.stored, [FakeCashuNative.backup(of: "lno1old")], "no second offer was made")
    }

    /// "No relay answered" must not read as "nothing backed up".
    func testNoNewOfferIsCreatedUntilTheRelaysAnswer() async throws {
        let native = FakeCashuNative()
        native.offer = nil
        native.createsOffer = "lno1new"
        let relay = FakeBackupRelay(stored: [FakeCashuNative.backup(of: "lno1old")])
        relay.answering = false
        let service = service(native, relay)

        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { service.connectivity == .online }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(service.receiveOffer, "no offer yet, rather than a new one over the backed-up one")
        XCTAssertNil(native.offer)

        relay.answering = true
        await waitUntil { service.receiveOffer == "lno1old" }
    }

    func testTheOfferIsBackedUpOnceAndAgainWhenItChanges() async throws {
        let native = FakeCashuNative()
        native.offer = "lno1a"
        let relay = FakeBackupRelay()
        let service = service(native, relay)

        await service.open(nsec: CashuTestFixtures.nsecA)
        await waitUntil { relay.published == [FakeCashuNative.backup(of: "lno1a")] }

        native.emit(.synced)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(relay.published, [FakeCashuNative.backup(of: "lno1a")], "unchanged: not republished")

        native.offer = "lno1b"
        native.emit(.synced)
        await waitUntil {
            relay.published == [FakeCashuNative.backup(of: "lno1a"), FakeCashuNative.backup(of: "lno1b")]
        }
    }
}
