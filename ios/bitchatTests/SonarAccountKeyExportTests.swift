import Foundation
import Testing
@testable import Sonar

/// Pins Settings → Export private key to the durable keychain path so the
/// sheet never depends on Marmot `workQueue` (Compose `identityNsec` parity).
///
/// The short-circuit tests pin the real preference helper used by
/// `SonarAppStore.exportNsec` / `MarmotChatModel.exportNsec` — a keychain hit
/// must not invoke the engine export closure.
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

    @Test
    func exportNsecPrefersKeychainAndSkipsEngine() async {
        let keychain = MockKeychain()
        let nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs2x0j2"
        #expect(keychain.saveIdentityKey(Data(nsec.utf8), forKey: SonarAccountKeyExport.marmotNsecKey))

        var engineCalls = 0
        let exported = await SonarAccountKeyExport.exportNsec(keychain: keychain) {
            engineCalls += 1
            return "nsec1engine-should-not-be-used"
        }
        #expect(exported == nsec)
        #expect(engineCalls == 0)
    }

    @Test
    func exportNsecFallsBackToEngineWhenKeychainEmpty() async {
        let keychain = MockKeychain()
        var engineCalls = 0
        let exported = await SonarAccountKeyExport.exportNsec(keychain: keychain) {
            engineCalls += 1
            return "nsec1from-engine-fallback-path-aaaaaaaaaaaaaaaaaaaa"
        }
        #expect(exported == "nsec1from-engine-fallback-path-aaaaaaaaaaaaaaaaaaaa")
        #expect(engineCalls == 1)
    }

    @Test
    func exportNsecFallsBackWhenKeychainUnreadable() async {
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data("nsec1ignored".utf8), forKey: SonarAccountKeyExport.marmotNsecKey)
        keychain.simulatedReadError = .deviceLocked

        var engineCalls = 0
        let exported = await SonarAccountKeyExport.exportNsec(keychain: keychain) {
            engineCalls += 1
            return "nsec1engine-while-device-locked-aaaaaaaaaaaaaaaaaa"
        }
        #expect(exported == "nsec1engine-while-device-locked-aaaaaaaaaaaaaaaaaa")
        #expect(engineCalls == 1)
    }
}
