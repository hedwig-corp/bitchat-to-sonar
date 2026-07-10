import Testing
@testable import Sonar

struct NearbyDiscoveryPolicyTests {
    @Test
    func nearbyScanRequiresVisibleForegroundRadarAndOpenDiscovery() {
        #expect(shouldScanForNearbyPayments(
            isNearbyVisible: true,
            isForeground: true,
            isDiscoveryRestricted: false
        ))
        #expect(!shouldScanForNearbyPayments(
            isNearbyVisible: false,
            isForeground: true,
            isDiscoveryRestricted: false
        ))
        #expect(!shouldScanForNearbyPayments(
            isNearbyVisible: true,
            isForeground: false,
            isDiscoveryRestricted: false
        ))
        #expect(!shouldScanForNearbyPayments(
            isNearbyVisible: true,
            isForeground: true,
            isDiscoveryRestricted: true
        ))
    }
}
