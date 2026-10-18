package chat.bitchat.sonar

/**
 * Own-send follow (QA-150; Signal `CVScrollAction` on an outgoing message).
 *
 * [tick] is bumped when the composer hands a message to the store and
 * [tailKeyAtSend] records the newest feed key at that moment. The transcript
 * anchors its tail as soon as the newest row is a different one — the echo
 * landed (or the window reset to its newest page) — and never before, so a
 * stale list is not scrolled to a tail the echo is not part of yet.
 */
internal fun transcriptOwnSendShouldFollow(
    tick: Int,
    tailKeyAtSend: String?,
    newestKey: String?,
): Boolean = tick > 0 && newestKey != null && newestKey != tailKeyAtSend

/**
 * Map a policy decision onto Sonar's production pin enum.
 * Lockstep → [TranscriptTailPin.None]; the Phase 2 host applies Lockstep directly.
 */
internal fun transcriptDecisionToLegacyPin(
    decision: chat.hedwig.transcript.TranscriptScrollDecision,
): TranscriptTailPin = when (decision) {
    is chat.hedwig.transcript.TranscriptScrollDecision.Pin ->
        if (decision.animate) TranscriptTailPin.Animate else TranscriptTailPin.Snap
    chat.hedwig.transcript.TranscriptScrollDecision.Lockstep,
    chat.hedwig.transcript.TranscriptScrollDecision.Ignore,
    -> TranscriptTailPin.None
}
