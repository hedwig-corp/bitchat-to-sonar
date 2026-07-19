import Foundation
import Testing
@testable import Sonar

/// Pins Settings → Export private key to the durable keychain path so the
/// sheet never depends on Marmot `workQueue` (Compose `identityNsec` parity).
struct SonarAccountKeyExportTests {
    @Test
    func nsecFromKeychainReturnsPersistedAccountKey() {
        let keychain = MockKeychain()
        let nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs2x0j2"
        #expect(keychain.saveIdentityKey(Data(nsec.utf8), forKey: SonarAccountKeyExport.marmotNsecKey))
        #expect(SonarAccountKeyExport.nsecFromKeychain(keychain) == nsec)
    }

    @Test
    func nsecFromKeychainTrimsWhitespace() {
        let keychain = MockKeychain()
        let nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs2x0j2"
        #expect(keychain.saveIdentityKey(Data("  \(nsec)\n".utf8), forKey: SonarAccountKeyExport.marmotNsecKey))
        #expect(SonarAccountKeyExport.nsecFromKeychain(keychain) == nsec)
    }

    @Test
    func nsecFromKeychainReturnsNilWhenMissing() {
        let keychain = MockKeychain()
        #expect(SonarAccountKeyExport.nsecFromKeychain(keychain) == nil)
    }

    @Test
    func nsecFromKeychainReturnsNilOnAccessErrors() {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked
        #expect(SonarAccountKeyExport.nsecFromKeychain(keychain) == nil)

        keychain.simulatedReadError = .accessDenied
        #expect(SonarAccountKeyExport.nsecFromKeychain(keychain) == nil)
    }
}
