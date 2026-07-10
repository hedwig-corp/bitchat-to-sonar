package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NearbyDiscoveryPolicyTest {
    @Test
    fun nearbyScanRequiresVisibleForegroundOnboardedRadarAndOpenDiscovery() {
        assertTrue(shouldScanForNearbyPayments(true, true, true, false))
        assertFalse(shouldScanForNearbyPayments(false, true, true, false))
        assertFalse(shouldScanForNearbyPayments(true, false, true, false))
        assertFalse(shouldScanForNearbyPayments(true, true, false, false))
        assertFalse(shouldScanForNearbyPayments(true, true, true, true))
    }
}
