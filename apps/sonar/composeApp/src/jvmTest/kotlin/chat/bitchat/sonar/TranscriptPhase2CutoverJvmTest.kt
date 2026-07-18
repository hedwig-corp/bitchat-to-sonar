package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins the Phase 3 cutover contract on JVM: the owned-chrome transcript host
 * is production default ON, and only the explicit `=0` env/property kill
 * switch falls back to the legacy shell.
 */
class TranscriptPhase2CutoverJvmTest {

    @Test
    fun platformBit_defaultOn_unlessKillSwitch() {
        val killSwitchSet =
            System.getenv(SonarTranscriptPolicyHost.ENV_KEY) == "0" ||
                System.getProperty(SonarTranscriptPolicyHost.PROPERTY_KEY) == "0"
        assertEquals(!killSwitchSet, sonarTranscriptPolicyHostEnabled)
    }
}
