package chat.bitchat.sonar

import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class DiagnosticsShareIntentTest {
    @Test
    fun grantsReceiversReadAccessToTheDiagnosticsZip() {
        val uri = Uri.parse("content://chat.bitchat.sonar.fileprovider/media-share/diagnostics.zip")

        val intent = diagnosticsShareIntent(uri)

        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals("application/zip", intent.type)
        assertEquals(uri, IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
        assertEquals(uri, assertNotNull(intent.clipData).getItemAt(0).uri)
        assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
    }
}
