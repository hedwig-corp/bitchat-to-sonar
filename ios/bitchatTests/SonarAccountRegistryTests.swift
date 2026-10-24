import XCTest
import SonarCore
@testable import Sonar

/// The host facade over the core account registry. The registry's own
/// behaviour (cap, legacy slot, remove) is pinned in Rust
/// (`sonar_core::accounts::tests`); these pin the two things the host adds —
/// keychain naming per account and the "no registry yet" legacy fallback —
/// plus the end-to-end FFI round trip in a throwaway data dir.
///
/// Mirror of Compose `AccountSwitchTest`; keep the two in step.
final class SonarAccountRegistryTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The legacy account keeps the exact names every build before the
    /// switcher used, so registering it never moves a secret.
    func testLegacyTagKeepsTheUnsuffixedKeychainNames() {
        XCTAssertEqual(SonarAccountRegistry.nsecKeychainKey(tag: ""), "marmot-nsec")
        XCTAssertEqual(SonarAccountRegistry.dbKeychainKey(tag: ""), "marmot-db-key")
    }

    func testAddedAccountsGetSuffixedKeychainNames() {
        let tag = String(repeating: "ab", count: 32)
        XCTAssertEqual(SonarAccountRegistry.nsecKeychainKey(tag: tag), "marmot-nsec.\(tag)")
        XCTAssertEqual(SonarAccountRegistry.dbKeychainKey(tag: tag), "marmot-db-key.\(tag)")
    }

    /// Two accounts must never share a keychain item.
    func testDistinctTagsNeverCollide() {
        let a = SonarAccountRegistry.nsecKeychainKey(tag: String(repeating: "a", count: 64))
        let b = SonarAccountRegistry.nsecKeychainKey(tag: String(repeating: "b", count: 64))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, SonarAccountRegistry.nsecKeychainKey(tag: ""))
    }

    /// Registry round trip through the FFI: legacy in place, a second account
    /// under `accounts/<hex>/`, switch, and the legacy slot refusing a second
    /// key.
    func testRegistryRoundTripThroughFfi() throws {
        let dir = try tempDir()
        let legacy = SonarIdentity.generate()
        let other = SonarIdentity.generate()

        let afterLegacy = try accountRegistryRegisterLegacy(dataDir: dir.path, pubkey: legacy.pubkeyHex())
        XCTAssertEqual(afterLegacy.accounts.count, 1)
        XCTAssertEqual(afterLegacy.activePubkeyHex, legacy.pubkeyHex())
        let legacyEntry = SonarAccount(afterLegacy.accounts[0])
        XCTAssertTrue(legacyEntry.isLegacy)
        XCTAssertEqual(legacyEntry.secretTag, "")
        XCTAssertEqual(legacyEntry.dbPath, dir.appendingPathComponent("marmot.sqlite").path)
        XCTAssertEqual(legacyEntry.nsecKeychainKey, "marmot-nsec")

        let added = SonarAccount(try accountRegistryAdd(dataDir: dir.path, pubkey: other.npub(), label: " Work "))
        XCTAssertFalse(added.isLegacy)
        XCTAssertFalse(added.isActive, "adding does not switch")
        XCTAssertEqual(added.label, "Work")
        XCTAssertEqual(added.secretTag, other.pubkeyHex())
        XCTAssertTrue(added.dbPath.hasSuffix("/accounts/\(other.pubkeyHex())/marmot.sqlite"))
        XCTAssertEqual(added.nsecKeychainKey, "marmot-nsec.\(other.pubkeyHex())")

        let switched = SonarAccount(try accountRegistrySetActive(dataDir: dir.path, pubkey: other.pubkeyHex()))
        XCTAssertTrue(switched.isActive)
        XCTAssertEqual(try accountRegistryLoad(dataDir: dir.path).activePubkeyHex, other.pubkeyHex())

        XCTAssertThrowsError(
            try accountRegistryRegisterLegacy(dataDir: dir.path, pubkey: SonarIdentity.generate().pubkeyHex()),
            "the legacy slot belongs to one key"
        )
    }

    /// `shortNpub` is what rows show when there is no label.
    func testShortNpubKeepsPrefixAndSuffix() {
        let id = SonarIdentity.generate()
        let npub = id.npub()
        let info = try! accountRegistryAdd(dataDir: try tempDir().path, pubkey: npub, label: nil)
        let short = SonarAccount(info).shortNpub
        XCTAssertTrue(short.hasPrefix(String(npub.prefix(9))))
        XCTAssertTrue(short.hasSuffix(String(npub.suffix(4))))
        XCTAssertLessThan(short.count, npub.count)
    }
}
