//
// SonarLegacyWalletTests.swift
// bitchatTests
//
// The legacy Breez wallet rules: the delete gate (pure; anything unknown ⇒
// NOT safe), the presence check never constructs a Breez wallet when no
// legacy store exists, and account replacement archives (renames) a store
// instead of deleting it.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import XCTest
@testable import Sonar

@MainActor
final class SonarLegacyWalletTests: XCTestCase {

    // MARK: Delete gate matrix

    private func safeSnapshot() -> SonarLegacyWalletSnapshot {
        SonarLegacyWalletSnapshot(
            connected: true,
            syncedSinceConnect: true,
            confirmedSats: 0,
            pendingSendSats: 0,
            pendingReceiveSats: 0,
            refundableSwaps: 0,
            unsettledPayments: 0,
            hasHistory: true
        )
    }

    func testDeleteGateMatrix() {
        typealias B = SonarLegacyDeleteGate.Blocker
        // Only the fully-known, fully-empty, synced-on-this-connection
        // snapshot is safe. Payment HISTORY does not block deletion.
        XCTAssertNil(SonarLegacyDeleteGate.blocker(for: safeSnapshot()))

        var cases: [(String, SonarLegacyWalletSnapshot?, B)] = [("no snapshot", nil, .unknown)]
        func variant(_ name: String, _ expected: B, _ mutate: (inout SonarLegacyWalletSnapshot) -> Void) {
            var s = safeSnapshot()
            mutate(&s)
            cases.append((name, s, expected))
        }
        variant("disconnected", .notConnected) { $0.connected = false }
        variant("not synced since connect", .notSynced) { $0.syncedSinceConnect = false }
        variant("balance", .balance(1)) { $0.confirmedSats = 1 }
        variant("pending send", .pendingSend(5)) { $0.pendingSendSats = 5 }
        variant("pending receive", .pendingReceive(7)) { $0.pendingReceiveSats = 7 }
        variant("refundable swap", .refundableSwaps(1)) { $0.refundableSwaps = 1 }
        variant("unsettled payment", .unsettledPayments(2)) { $0.unsettledPayments = 2 }
        variant("unknown balance", .unknown) { $0.confirmedSats = nil }
        variant("unknown pending send", .unknown) { $0.pendingSendSats = nil }
        variant("unknown pending receive", .unknown) { $0.pendingReceiveSats = nil }
        variant("unknown refundables", .unknown) { $0.refundableSwaps = nil }
        variant("unknown payments", .unknown) { $0.unsettledPayments = nil }
        // Connection/sync are checked first: a stale snapshot never passes,
        // whatever it says.
        variant("disconnected but empty", .notConnected) { $0.connected = false; $0.confirmedSats = 0 }
        variant("unsynced with balance", .notSynced) { $0.syncedSinceConnect = false; $0.confirmedSats = 9 }

        for (name, snapshot, expected) in cases {
            XCTAssertEqual(SonarLegacyDeleteGate.blocker(for: snapshot), expected, name)
        }
    }

    func testDeleteGateReasonsAreUserFacing() {
        let money: (Int64) -> String = { "\($0) sats" }
        XCTAssertTrue(SonarLegacyDeleteGate.message(for: .balance(1_500), money: money).contains("1500 sats"))
        for blocker: SonarLegacyDeleteGate.Blocker in [.unknown, .notConnected, .notSynced, .pendingSend(1),
                                                       .pendingReceive(1), .refundableSwaps(1), .unsettledPayments(1)] {
            XCTAssertFalse(SonarLegacyDeleteGate.message(for: blocker, money: money).isEmpty)
        }
    }

    // MARK: Presence check

    private func storage(_ root: URL, defaults: UserDefaults) -> SonarLegacyWalletStorage {
        SonarLegacyWalletStorage(
            fileManager: .default,
            appGroupContainer: root.appendingPathComponent("group", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
            sharedDefaults: nil,
            defaults: defaults
        )
    }

    /// No legacy store on the device ⇒ the presence check constructs NO
    /// Breez wallet (and so never runs Breez setup, which could create one).
    func testLegacyAbsentConstructsNoBreezWallet() throws {
        let root = try CashuTestFixtures.tempDirectory("legacy-absent")
        let (defaults, suite) = CashuTestFixtures.defaults()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        var constructed: [LegacyBreezWallet.Mode] = []
        func coordinator(_ presence: SonarLegacyPresence, apiKey: Bool = true) -> SonarLegacyWalletCoordinator {
            SonarLegacyWalletCoordinator(
                storage: storage(root, defaults: defaults),
                presence: { presence },
                hasAPIKey: { apiKey },
                nsecProvider: { CashuTestFixtures.nsecA },
                factory: { mode in
                    constructed.append(mode)
                    XCTFail("no Breez wallet may be constructed when legacy is absent")
                    return LegacyBreezWallet(mode: mode, keychain: MockKeychain())
                }
            )
        }

        let absent = coordinator(.absent)
        absent.refresh()
        XCTAssertNil(absent.wallet)

        // Keychain unreadable: decide later, construct nothing now.
        let unknown = coordinator(.unknown)
        unknown.refresh()
        XCTAssertNil(unknown.wallet)

        // A pending restore check does not run without a Breez API key.
        storage(root, defaults: defaults).armRestoreCheck(CashuTestFixtures.accountIdA)
        let keyless = coordinator(.absent, apiKey: false)
        keyless.refresh()
        XCTAssertNil(keyless.wallet)

        XCTAssertEqual(constructed, [])
    }

    /// The restore check runs once per account: arming it after it has
    /// completed is a no-op.
    func testRestoreCheckRunsOncePerAccount() {
        let (defaults, suite) = CashuTestFixtures.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = storage(URL(fileURLWithPath: NSTemporaryDirectory()), defaults: defaults)
        let id = CashuTestFixtures.accountIdA
        s.armRestoreCheck(id)
        XCTAssertTrue(s.restoreCheckPending(id))
        s.completeRestoreCheck(id)
        XCTAssertFalse(s.restoreCheckPending(id))
        s.armRestoreCheck(id)
        XCTAssertFalse(s.restoreCheckPending(id), "a completed check never re-arms")
        XCTAssertFalse(s.restoreCheckPending(CashuTestFixtures.accountIdB))
    }

    // MARK: Archive (account replacement)

    /// Replacement with a non-empty legacy store renames it to
    /// `<root>-archive/<oldAccountId>` (same volume, nothing deleted), and it
    /// comes back when that account is restored.
    func testArchiveRenamesTheStoreAndRestoresItForTheSameAccount() throws {
        let root = try CashuTestFixtures.tempDirectory("legacy-archive")
        let (defaults, suite) = CashuTestFixtures.defaults()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let s = storage(root, defaults: defaults)
        let fm = FileManager.default
        let live = root.appendingPathComponent("group/breez-sdk/mainnet", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("breez-db".utf8).write(to: live.appendingPathComponent("storage.sql"))

        try s.archiveStore(accountId: "old-account")

        let archived = root.appendingPathComponent("group/breez-sdk-archive/old-account/mainnet/storage.sql")
        XCTAssertTrue(fm.fileExists(atPath: archived.path), "store moved, not deleted")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("group/breez-sdk").path))
        XCTAssertTrue(s.hasArchive(accountId: "old-account"))
        XCTAssertFalse(s.hasArchive(accountId: "someone-else"))

        // Another account never gets it back.
        XCTAssertFalse(try s.restoreArchive(accountId: "someone-else"))
        // The same account does.
        XCTAssertTrue(try s.restoreArchive(accountId: "old-account"))
        XCTAssertTrue(fm.fileExists(atPath: live.appendingPathComponent("storage.sql").path))
        XCTAssertFalse(s.hasArchive(accountId: "old-account"))
    }

    /// Archiving twice for the same account never overwrites the first
    /// archive.
    func testArchiveNeverOverwritesAnEarlierArchive() throws {
        let root = try CashuTestFixtures.tempDirectory("legacy-archive-twice")
        let (defaults, suite) = CashuTestFixtures.defaults()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let s = storage(root, defaults: defaults)
        let fm = FileManager.default
        let live = root.appendingPathComponent("group/breez-sdk", isDirectory: true)
        for generation in ["first", "second"] {
            try fm.createDirectory(at: live, withIntermediateDirectories: true)
            try Data(generation.utf8).write(to: live.appendingPathComponent("db"))
            try s.archiveStore(accountId: "acct")
        }
        let archive = root.appendingPathComponent("group/breez-sdk-archive", isDirectory: true)
        let first = try String(contentsOf: archive.appendingPathComponent("acct/db"), encoding: .utf8)
        let second = try String(contentsOf: archive.appendingPathComponent("acct-2/db"), encoding: .utf8)
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
    }
}
