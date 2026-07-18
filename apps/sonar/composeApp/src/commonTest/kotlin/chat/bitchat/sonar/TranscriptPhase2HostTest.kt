package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Phase 2 Compose host helpers (distinct from [TranscriptScrollPolicyTest]).
 * Pins OpenAction→index, Lockstep delta, and the Phase 3 cutover default-ON
 * flag with its `=0` kill switch.
 */
class TranscriptPhase2HostTest {

    @Test
    fun openIndex_liveEdge_isLast() {
        assertEquals(
            9,
            transcriptPhase2OpenIndex(
                openAction = TranscriptOpenAction.LiveEdge,
                unreadAnchorIndex = 3,
                itemCount = 10,
            ),
        )
    }

    @Test
    fun openIndex_unreadDivider_usesAnchor() {
        assertEquals(
            4,
            transcriptPhase2OpenIndex(
                openAction = TranscriptOpenAction.UnreadDivider,
                unreadAnchorIndex = 4,
                itemCount = 10,
            ),
        )
    }

    @Test
    fun openIndex_unreadDivider_missingAnchor_isPending() {
        assertEquals(
            -1,
            transcriptPhase2OpenIndex(
                openAction = TranscriptOpenAction.UnreadDivider,
                unreadAnchorIndex = -1,
                itemCount = 10,
            ),
        )
    }

    @Test
    fun openIndex_jump_usesJumpIndex() {
        assertEquals(
            7,
            transcriptPhase2OpenIndex(
                openAction = TranscriptOpenAction.Jump("m:search"),
                unreadAnchorIndex = 2,
                itemCount = 10,
                jumpIndex = 7,
            ),
        )
    }

    @Test
    fun lockstepDelta_passesThroughInsetChange() {
        assertEquals(120, transcriptPhase2LockstepScrollDelta(120))
        assertEquals(-80, transcriptPhase2LockstepScrollDelta(-80))
        assertEquals(0, transcriptPhase2LockstepScrollDelta(0))
    }

    @Test
    fun decideInsetChange_inHistory_isLockstep_notNone() {
        // Flagged host must apply this; production toLegacyPin still maps → None.
        assertEquals(
            TranscriptScrollDecision.Lockstep,
            TranscriptScrollPolicy.decideInsetChange(
                wasAtTail = false,
                userScrolling = false,
                prepending = false,
            ),
        )
        assertEquals(
            TranscriptTailPin.None,
            TranscriptScrollPolicy.toLegacyPin(TranscriptScrollDecision.Lockstep),
        )
    }

    @Test
    fun flag_followsPlatformBit_andForceLatch() {
        val previous = SonarTranscriptPolicyHost.forceEnabled
        try {
            // Force path still latches on regardless of the platform bit.
            SonarTranscriptPolicyHost.forceEnabled = true
            assertTrue(SonarTranscriptPolicyHost.isEnabled())
            // Un-forced, the platform bit decides (Phase 3 cutover default ON;
            // TranscriptPhase2CutoverJvmTest pins the `=0` kill-switch shape).
            SonarTranscriptPolicyHost.forceEnabled = false
            assertEquals(sonarTranscriptPolicyHostEnabled, SonarTranscriptPolicyHost.isEnabled())
        } finally {
            SonarTranscriptPolicyHost.forceEnabled = previous
        }
    }
}
