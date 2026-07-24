import Testing
@testable import Sonar

/// The verified badge is keyed by npub+address. Keying it by address alone let
/// one contact's verdict answer for another's, and the badge branch reading a
/// key nobody wrote meant the checkmark never rendered at all while the handle
/// text still did, making a genuine handle and a forged kind-0 claiming the
/// same string indistinguishable.
struct Nip05BadgeCacheKeyTests {
    private let address = "vincenzo@sonarprivacy.xyz"
    private let npubA = "npub1vfka7aqh75juhlw75lwt6zrp36eupv406m9clln7m4mrtzutnnfsnzuzce"
    private let npubB = "npub1ysxjlcg5zz8kyx2alegflkqx89dn2w583wc3k3nzgpr3hgffgn9qx0ktfc"

    @Test
    func sameHandleClaimedByDifferentKeysGetsDifferentEntries() {
        let keyA = SonarContactProfileScreen.nip05CacheKey(npub: npubA, address: address)
        let keyB = SonarContactProfileScreen.nip05CacheKey(npub: npubB, address: address)
        #expect(keyA != keyB)
    }

    @Test
    func keyIncludesBothNpubAndAddress() {
        let key = SonarContactProfileScreen.nip05CacheKey(npub: npubA, address: address)
        #expect(key.contains(address))
        #expect(key != address)
        #expect(!key.isEmpty)
    }

    /// The write site canonicalizes the npub; a read site that passed a raw or
    /// differently-cased form must still land on the same entry.
    @Test
    func keyIsStableAcrossEquivalentNpubForms() {
        let padded = "  \(npubA)  "
        #expect(
            SonarContactProfileScreen.nip05CacheKey(npub: npubA, address: address)
                == SonarContactProfileScreen.nip05CacheKey(npub: padded, address: address)
        )
    }

    @Test
    func differentAddressesForOneKeyStaySeparate() {
        #expect(
            SonarContactProfileScreen.nip05CacheKey(npub: npubA, address: address)
                != SonarContactProfileScreen.nip05CacheKey(npub: npubA, address: "other@example.com")
        )
    }
}
