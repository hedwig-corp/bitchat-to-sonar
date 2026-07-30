//
// SonarTranscriptRecoveryPolicyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing

@testable import Sonar

/// R-018 (iOS half, #450) — "core is not readable yet" and "this conversation
/// has no messages" must not reach the UI as the same answer. Mirror of the
/// Compose `TranscriptDisplayPolicyTest` gate cases.
struct SonarTranscriptRecoveryPolicyTests {

    @Test
    func recoveryRunsWhenLocalMetadataKnowsMessages() {
        // The reported symptom: the summary says there are messages, the
        // transcript painted none. Never accept that as the answer.
        #expect(SonarTranscriptRecoveryPolicy.shouldRecoverBlankTranscript(
            knownNonEmpty: true, storeReadable: true, sourcesResolved: true))
    }

    @Test
    func recoveryRunsWhenEmptinessCannotBeProven() {
        // Store not readable yet (cold launch): absence of evidence only.
        #expect(SonarTranscriptRecoveryPolicy.shouldRecoverBlankTranscript(
            knownNonEmpty: false, storeReadable: false, sourcesResolved: true))
        // Pending conversation whose Marmot group has not resolved: the read
        // was aimed at an id that cannot answer for the real history.
        #expect(SonarTranscriptRecoveryPolicy.shouldRecoverBlankTranscript(
            knownNonEmpty: false, storeReadable: true, sourcesResolved: false))
    }

    @Test
    func recoverySkipsAConversationProvenEmpty() {
        // A chat just created has nothing to find — retrying forever would
        // burn reads on every new conversation.
        #expect(!SonarTranscriptRecoveryPolicy.shouldRecoverBlankTranscript(
            knownNonEmpty: false, storeReadable: true, sourcesResolved: true))
    }

    @Test
    func recoveryBudgetIsBoundedAndShort() {
        // A safety net, not a polling loop: bounded total, and the first
        // retry lands fast enough to be invisible when it works.
        #expect(SonarTranscriptRecoveryPolicy.recoveryDelays.first == 0.1)
        #expect(SonarTranscriptRecoveryPolicy.recoveryBudgetSeconds <= 10.0)
        #expect(SonarTranscriptRecoveryPolicy.recoveryBudgetSeconds >= 3.0)
        // Backoff, not a fixed interval.
        #expect(SonarTranscriptRecoveryPolicy.recoveryDelays[1]
                > SonarTranscriptRecoveryPolicy.recoveryDelays[0])
    }
}
