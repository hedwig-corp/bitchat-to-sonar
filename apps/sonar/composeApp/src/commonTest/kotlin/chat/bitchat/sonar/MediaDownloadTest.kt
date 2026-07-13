package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class MediaDownloadTest {
    @Test
    fun cacheKeysAreStableOpaqueNames() {
        val url = "https://media.example/receipts/receipt.pdf?token=secret"
        val key = mediaCacheKey(url)

        assertEquals(key, mediaCacheKey(url))
        assertEquals(64, key.length)
        assertTrue(key.all { it in '0'..'9' || it in 'a'..'f' })
        assertFalse(key.contains("receipt"))
        assertNotEquals(key, mediaCacheKey("$url&part=2"))
    }

    @Test
    fun controlForwardsProgressAndMakesCancellationSticky() {
        var received = 0uL
        var total: ULong? = null
        val control = MediaDownloadControl { nextReceived, nextTotal ->
            received = nextReceived
            total = nextTotal
        }

        control.onProgress(512uL, 1024uL)
        assertEquals(512uL, received)
        assertEquals(1024uL, total)
        assertFalse(control.isCancelled())

        control.cancel()
        assertTrue(control.isCancelled())
        control.onProgress(1024uL, 1024uL)
        assertTrue(control.isCancelled())
    }

    @Test
    fun availableStateCarriesOnlyTheCompletedLocalFile() {
        val state = MediaTransferState.available("/private/media/receipt")

        assertEquals(MediaTransferPhase.Available, state.phase)
        assertEquals(1f, state.progress)
        assertEquals("/private/media/receipt", state.localPath)
    }
}
