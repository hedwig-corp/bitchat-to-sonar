package chat.bitchat.sonar

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
