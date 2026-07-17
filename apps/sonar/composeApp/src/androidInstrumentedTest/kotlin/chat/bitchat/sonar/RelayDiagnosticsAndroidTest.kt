package chat.bitchat.sonar

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RelayDiagnosticsAndroidTest {

    @Test
    fun parseSnapshotExtractsRelayEntriesOnAndroid() {
        val snapshot = parseSyncStateSnapshot(
            """
            {
              "watermark_secs": 1710000000,
              "live_marmot_enabled": true,
              "subscribed_group_count": 3,
              "relays": [
                {"url": "wss://nostr.relay.hedwig.sh/", "status": "Connected"},
                {"url": "wss://relay.damus.io", "status": "disconnected"}
              ]
            }
            """.trimIndent(),
        )

        assertNotNull(snapshot)
        assertEquals(2, snapshot!!.relays.size)
        assertEquals("wss://nostr.relay.hedwig.sh/", snapshot.relays[0].url)
        assertEquals("Connected", snapshot.relays[0].status)
        assertEquals("wss://relay.damus.io", snapshot.relays[1].url)
        assertEquals("disconnected", snapshot.relays[1].status)
    }
}
