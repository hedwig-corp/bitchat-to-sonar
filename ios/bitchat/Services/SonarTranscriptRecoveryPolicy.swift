//
// SonarTranscriptRecoveryPolicy.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Apple mirror of Compose `TranscriptDisplayPolicy` (regression ledger
/// **R-018**, iOS half tracked as #450).
///
/// The invariant: a local transcript read that returns nothing may only be
/// painted when the store was actually readable. "Core is not readable yet"
/// and "this conversation has no messages" must not reach the UI as the same
/// answer.
///
/// The Apple read path already gets the first half right — `MarmotService`'s
/// lanes THROW when no node is leased, so an unreadable store never returns
/// an empty page that could be committed. What was missing is the second
/// half: after an open that painted nothing, nothing re-read local storage,
/// so the chat stayed blank until an unrelated sync event published rows.
enum SonarTranscriptRecoveryPolicy {

    /// Whether a transcript that opened blank should keep re-reading local
    /// storage.
    ///
    /// The gate exists to avoid retrying on a conversation that is genuinely
    /// empty — a chat just created has nothing to find. But absence of
    /// evidence is not evidence of absence: before the store is readable, or
    /// before a pending conversation resolves to a real Marmot group, "we
    /// know of no messages" only means the metadata has not loaded.
    /// Recovering in that state costs a handful of bounded local page reads;
    /// skipping it leaves the chat black, which is the bug this exists for.
    ///
    /// - Parameters:
    ///   - knownNonEmpty: local metadata (a conversation summary) proves the
    ///     conversation has at least one message.
    ///   - storeReadable: the encrypted store answered a read at all.
    ///   - sourcesResolved: the conversation's transport legs are resolved (a
    ///     pending/mesh-folded chat with no Marmot group yet is not).
    static func shouldRecoverBlankTranscript(
        knownNonEmpty: Bool,
        storeReadable: Bool,
        sourcesResolved: Bool
    ) -> Bool {
        knownNonEmpty || !storeReadable || !sourcesResolved
    }

    /// Backoff schedule for the recovery re-reads, in seconds. Bounded on
    /// purpose: this is a safety net for a first paint that lost a race with
    /// store readiness, not a polling loop. Mirrors the Compose budget
    /// (~8s total, 100ms → 800ms).
    static let recoveryDelays: [Double] = [0.1, 0.2, 0.4, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8]

    /// Total wall-clock ceiling of [`recoveryDelays`], for tests and docs.
    static var recoveryBudgetSeconds: Double { recoveryDelays.reduce(0, +) }
}
