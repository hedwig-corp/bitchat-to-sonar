//
// SNTranscriptHostRenderContextRevisionTests.swift
// bitchatTests
//
// Regression: SwiftUI `body` runs BEFORE `prepareForUpdate`'s `sync`, so the
// contentVersion shipped to the collection host must be the revision `sync`
// WILL produce for this pass's renderState — not a raw read of the stored
// revision. A raw (pre-sync) read is one bump stale: the pass that carries a
// real row change (a send, or the optimistic-echo → canonical swap) compares
// equal to the last applied version and `shouldSkipUnchangedApply` swallows
// it. The host then keeps a stale snapshot holding a dead row id, which
// renders as a blank band above the keyboard and collapses on the next
// scroll-triggered re-measure until a forced apply (often the "Sent" summary
// refresh) lands.
//
// Upstream row identity is `SNConversationRenderState.revision` (R-041): the
// adapter must not re-walk `[SNMessage]` equality on every body evaluation.
//

#if os(iOS)
import Testing
import TranscriptEngine

@testable import Sonar

@MainActor
struct SNTranscriptHostRenderContextRevisionTests {

    private func makeMessage(id: String, text: String) -> SNMessage {
        SNMessage(id: id, mine: true, text: text, time: "10:00")
    }

    private func state(_ messages: [SNMessage], revision: UInt64) -> SNConversationRenderState {
        .make(messages: messages, revision: revision)
    }

    private func sync(
        _ context: SNTranscriptHostRenderContext,
        renderState: SNConversationRenderState,
        showAuthors: Bool = false,
        peerName: String = "Peer"
    ) {
        context.sync(
            renderState: renderState,
            showAuthors: showAuthors,
            peerName: peerName,
            money: { _ in "" },
            fiatText: { _ in nil },
            onTapAuthor: nil,
            mediaPipeline: .unavailable,
            loadSticker: nil,
            onTapPack: nil,
            onRetry: nil,
            onCancelUpload: nil,
            uploadProgressSource: nil,
            onReply: nil,
            onJumpQuote: nil,
            onTapMention: nil
        )
    }

    /// The value read at body time must equal the value `sync` stores for the
    /// same inputs — that is the whole contract: entries and contentVersion
    /// describe the same snapshot.
    @Test
    func predictedVersionMatchesPostSyncRevision() {
        let context = SNTranscriptHostRenderContext()
        let msgsA = [makeMessage(id: "a", text: "hi")]
        let stateA = state(msgsA, revision: 1)

        let openVersion = context.contentVersion(afterSyncing: stateA, showAuthors: false, peerName: "Peer")
        sync(context, renderState: stateA)
        #expect(context.contentVersion(afterSyncing: stateA, showAuthors: false, peerName: "Peer") == openVersion)

        let msgsB = msgsA + [makeMessage(id: "optimistic-1", text: "new send")]
        let stateB = state(msgsB, revision: 2)
        let sendVersion = context.contentVersion(afterSyncing: stateB, showAuthors: false, peerName: "Peer")
        #expect(sendVersion == openVersion &+ 1)
        sync(context, renderState: stateB)
        #expect(context.contentVersion(afterSyncing: stateB, showAuthors: false, peerName: "Peer") == sendVersion)

        let flipVersion = context.contentVersion(afterSyncing: stateB, showAuthors: true, peerName: "Peer")
        #expect(flipVersion == sendVersion &+ 1)
        sync(context, renderState: stateB, showAuthors: true)
        #expect(context.contentVersion(afterSyncing: stateB, showAuthors: true, peerName: "Peer") == flipVersion)
    }

    @Test
    func peerNameChangeBumpsRevision() {
        let context = SNTranscriptHostRenderContext()
        let msgs = [makeMessage(id: "a", text: "hi")]
        let openState = state(msgs, revision: 1)

        let openVersion = context.contentVersion(afterSyncing: openState, showAuthors: false, peerName: "")
        sync(context, renderState: openState, peerName: "")

        let renamed = context.contentVersion(afterSyncing: openState, showAuthors: false, peerName: "Alice")
        #expect(renamed == openVersion &+ 1)
        sync(context, renderState: openState, peerName: "Alice")
        #expect(context.contentVersion(afterSyncing: openState, showAuthors: false, peerName: "Alice") == renamed)
    }

    @Test
    func rowChangePassIsNeverSkippedAfterIdleApply() {
        let context = SNTranscriptHostRenderContext()
        var lastApplied: UInt64?

        func passes(renderState: SNConversationRenderState) -> Bool {
            let version = context.contentVersion(afterSyncing: renderState, showAuthors: false, peerName: "Peer")
            sync(context, renderState: renderState)
            let skipped = TranscriptScrollPolicy.shouldSkipUnchangedApply(
                contentVersion: version,
                lastContentVersion: lastApplied,
                unreadCountAtOpen: nil,
                lastUnreadCountAtOpen: nil,
                jumpMessageId: nil,
                lastJumpMessageId: nil,
                expectedNewestDate: nil,
                lastExpectedNewestDate: nil
            )
            if !skipped { lastApplied = version }
            return !skipped
        }

        let history = [makeMessage(id: "a", text: "hi")]
        #expect(passes(renderState: state(history, revision: 1)), "open pass must apply")
        _ = passes(renderState: state(history, revision: 1)) // idle — may skip

        let withEcho = history + [makeMessage(id: "optimistic-1", text: "on my way")]
        #expect(passes(renderState: state(withEcho, revision: 2)), "send pass must apply the new echo row")
        _ = passes(renderState: state(withEcho, revision: 2))

        let withCanonical = history + [makeMessage(id: "canonical-1", text: "on my way")]
        #expect(
            passes(renderState: state(withCanonical, revision: 3)),
            "echo → canonical swap must apply, or the snapshot keeps a dead row id"
        )
    }

    @Test
    func unchangedPassStillSkips() {
        let context = SNTranscriptHostRenderContext()
        let msgs = [makeMessage(id: "a", text: "hi")]
        let openState = state(msgs, revision: 1)

        let openVersion = context.contentVersion(afterSyncing: openState, showAuthors: false, peerName: "Peer")
        sync(context, renderState: openState)

        let idleVersion = context.contentVersion(afterSyncing: openState, showAuthors: false, peerName: "Peer")
        sync(context, renderState: openState)
        let skipped = TranscriptScrollPolicy.shouldSkipUnchangedApply(
            contentVersion: idleVersion,
            lastContentVersion: openVersion,
            unreadCountAtOpen: nil,
            lastUnreadCountAtOpen: nil,
            jumpMessageId: nil,
            lastJumpMessageId: nil,
            expectedNewestDate: nil,
            lastExpectedNewestDate: nil
        )
        #expect(skipped, "identical transcript must keep skipping the rebuild")
    }

    @Test
    func unchangedRevisionDoesNotRebuildMessageIndex() {
        let context = SNTranscriptHostRenderContext()
        let msgs = [makeMessage(id: "a", text: "hi"), makeMessage(id: "b", text: "there")]
        let openState = state(msgs, revision: 1)
        sync(context, renderState: openState)
        let indexAfterOpen = context.msgIndexByID
        #expect(indexAfterOpen["a"] == 0)
        #expect(indexAfterOpen["b"] == 1)

        // Same revision + same chrome: sync must not allocate a new index map
        // walk — identity of the stored dictionary is preserved (CoW assign skip).
        sync(context, renderState: openState)
        #expect(context.msgIndexByID == indexAfterOpen)
        #expect(context.upstreamRenderRevision == 1)
    }

    @Test
    func advancedRenderStateKeepsRevisionWhenMessagesUnchanged() {
        let first = snAdvancedConversationRenderState(previous: .empty, messages: [
            makeMessage(id: "a", text: "hi"),
        ])
        #expect(first.revision == 1)
        #expect(first.messageIndexByID["a"] == 0)

        let second = snAdvancedConversationRenderState(previous: first, messages: first.messages)
        #expect(second.revision == first.revision)
        #expect(second.messages == first.messages)

        let third = snAdvancedConversationRenderState(
            previous: first,
            messages: first.messages + [makeMessage(id: "b", text: "yo")]
        )
        #expect(third.revision == first.revision &+ 1)
        #expect(third.messageIndexByID["b"] == 1)
    }
}

#endif
