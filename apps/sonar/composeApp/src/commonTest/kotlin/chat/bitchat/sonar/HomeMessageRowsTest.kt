package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class HomeMessageRowsTest {

    private fun mesh(peerId: String, ts: Long) =
        MeshDmRow(peerId = peerId, name = peerId, preview = "m", tsSecs = ts)

    private fun chat(id: String) =
        SonarChat(id = id, name = id, members = emptyList())

    @Test
    fun mergesMeshAndMarmotByRecencyDescending() {
        val meshRows = listOf(mesh("ble-old", 100), mesh("ble-new", 300))
        val chatRows = listOf(chat("g-mid"), chat("g-newest"))
        val ts = mapOf("g-mid" to 200L, "g-newest" to 400L)

        val merged = mergeHomeMessageRows(meshRows, chatRows) { ts[it] ?: 0L }

        assertEquals(
            listOf("g-newest", "mesh:ble-new", "g-mid", "mesh:ble-old"),
            merged.map { it.listKey },
        )
    }

    @Test
    fun pendingCreationTimeSortsAboveOlderHistory() {
        // Freshly-started pending chat (createdAt=500) must not sink under a
        // mesh conversation from last week (ts=100) — iOS dmRows parity.
        val meshRows = listOf(mesh("old-ble", 100))
        val chatRows = listOf(chat("npub:pending"))
        val ts = mapOf("npub:pending" to 500L)

        val merged = mergeHomeMessageRows(meshRows, chatRows) { ts[it] ?: 0L }

        assertEquals("npub:pending", merged.first().listKey)
        assertIs<HomeMessageRow.Marmot>(merged.first())
    }

    @Test
    fun zeroTsWithoutCreationTimeSortsLast() {
        val meshRows = listOf(mesh("active", 50))
        val chatRows = listOf(chat("empty"))
        val merged = mergeHomeMessageRows(meshRows, chatRows) { 0L }
        assertEquals("mesh:active", merged.first().listKey)
        assertEquals("empty", merged.last().listKey)
    }

    @Test
    fun listKeysAreNamespacedPerTransport() {
        val merged = mergeHomeMessageRows(
            listOf(mesh("abc", 1)),
            listOf(chat("group-1")),
        ) { 1L }
        assertTrue(merged.any { it.listKey == "mesh:abc" })
        assertTrue(merged.any { it.listKey == "group-1" })
    }
}
