package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SignalTranscriptSpikeATest {

    @Test
    fun forceEnabled_optsInWithoutPlatformEnv() {
        val previous = SignalTranscriptSpikeA.forceEnabled
        try {
            SignalTranscriptSpikeA.forceEnabled = false
            // Platform env may or may not be set in CI; force path must work.
            SignalTranscriptSpikeA.forceEnabled = true
            assertTrue(SignalTranscriptSpikeA.isEnabled())
            SignalTranscriptSpikeA.forceEnabled = false
            // When force is off, enabled only if platform env/property says so —
            // do not assert false here (dev shells may export the spike env).
            if (!signalTranscriptSpikeAPlatformEnabled()) {
                assertFalse(SignalTranscriptSpikeA.isEnabled())
            }
        } finally {
            SignalTranscriptSpikeA.forceEnabled = previous
        }
    }
}
