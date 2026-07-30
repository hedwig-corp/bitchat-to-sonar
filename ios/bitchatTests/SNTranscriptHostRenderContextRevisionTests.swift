//
// SNTranscriptHostRenderContextRevisionTests.swift
// bitchatTests
//
// Regression: SwiftUI `body` runs BEFORE `prepareForUpdate`'s `sync`, so the
// contentVersion shipped to the collection host must be the revision `sync`
// WILL produce for this pass's msgs — not a raw read of the stored revision.
// A raw (pre-sync) read is one bump stale: the pass that carries a real row
// change (a send, or the optimistic-echo → canonical swap) compares equal to
// the last applied version and `shouldSkipUnchangedApply` swallows it. The
// host then keeps a stale snapshot holding a dead row id, which renders as a
// blank band above the keyboard and collapses on the next scroll-triggered
// re-measure until a forced apply (often the "Sent" summary refresh) lands.
//
// `SNTranscriptHostRenderContext.contentRevision` is private so the raw-read
// call-site shape no longer compiles; these tests pin the accessor's contract
// against the real `TranscriptScrollPolicy.shouldSkipUnchangedApply`.
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

    private func sync(
        _ context: SNTranscriptHostRenderContext,
        msgs: [SNMessage],
        showAuthors: Bool = false,
        peerName: String = "Peer"
    ) {
        context.sync(
            msgs: msgs,
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
            uploadProgressSource: nil
        )
    }

    /// The value read at body time must equal the value `sync` stores for the
    /// same inputs — that is the whole contract: entries and contentVersion
    /// describe the same snapshot.
    @Test
    func predictedVersionMatchesPostSyncRevision() {
        let context = SNTranscriptHostRenderContext()
        let msgsA = [makeMessage(id: "a", text: "hi")]

        let openVersion = context.contentVersion(afterSyncing: msgsA, showAuthors: false, peerName: "Peer")
        sync(context, msgs: msgsA)
        #expect(context.contentVersion(afterSyncing: msgsA, showAuthors: false, peerName: "Peer") == openVersion)

        let msgsB = msgsA + [makeMessage(id: "optimistic-1", text: "new send")]
        let sendVersion = context.contentVersion(afterSyncing: msgsB, showAuthors: false, peerName: "Peer")
        #expect(sendVersion == openVersion &+ 1)
        sync(context, msgs: msgsB)
        #expect(context.contentVersion(afterSyncing: msgsB, showAuthors: false, peerName: "Peer") == sendVersion)

        // A showAuthors flip with an identical transcript (group membership
        // resolving after open) is a row-affecting change too: the prediction
        // must bump exactly as sync will, or the flip pass gets skipped and
        // author labels never appear until the next row change.
        let flipVersion = context.contentVersion(afterSyncing: msgsB, showAuthors: true, peerName: "Peer")
        #expect(flipVersion == sendVersion &+ 1)
        sync(context, msgs: msgsB, showAuthors: true)
        #expect(context.contentVersion(afterSyncing: msgsB, showAuthors: true, peerName: "Peer") == flipVersion)
    }

    /// A peer display name resolving after open (notification-tap open before
    /// contact metadata loads) is row content for nudge/pay bubbles: the
    /// prediction must bump exactly as sync will, or the rename pass is
    /// skipped and those rows keep the stale/empty name.
    @Test
    func peerNameChangeBumpsRevision() {
        let context = SNTranscriptHostRenderContext()
        let msgs = [makeMessage(id: "a", text: "hi")]

        let openVersion = context.contentVersion(afterSyncing: msgs, showAuthors: false, peerName: "")
        sync(context, msgs: msgs, peerName: "")

        let renamed = context.contentVersion(afterSyncing: msgs, showAuthors: false, peerName: "Alice")
        #expect(renamed == openVersion &+ 1)
        sync(context, msgs: msgs, peerName: "Alice")
        #expect(context.contentVersion(afterSyncing: msgs, showAuthors: false, peerName: "Alice") == renamed)
    }

    /// The bug's exact pass sequence: open → idle publish (keystroke) → send.
    /// With a pre-sync read the send pass's version equals the last applied
    /// version and the apply carrying the new row is skipped. The predicted
    /// version must keep every row-change pass applying.
    @Test
    func rowChangePassIsNeverSkippedAfterIdleApply() {
        let context = SNTranscriptHostRenderContext()
        var lastApplied: UInt64?

        func passes(msgs: [SNMessage]) -> Bool {
            let version = context.contentVersion(afterSyncing: msgs, showAuthors: false, peerName: "Peer")
            sync(context, msgs: msgs)
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
        #expect(passes(msgs: history), "open pass must apply")
        _ = passes(msgs: history) // idle publish (composer keystroke) — may skip

        let withEcho = history + [makeMessage(id: "optimistic-1", text: "on my way")]
        #expect(passes(msgs: withEcho), "send pass must apply the new echo row")
        _ = passes(msgs: withEcho) // idle publish between send and canonical swap

        let withCanonical = history + [makeMessage(id: "canonical-1", text: "on my way")]
        #expect(
            passes(msgs: withCanonical),
            "echo → canonical swap must apply, or the snapshot keeps a dead row id"
        )
    }

    /// The #391 optimization must survive the fix: a pass with unchanged rows
    /// and unchanged open-action inputs still skips the O(n) snapshot rebuild.
    @Test
    func unchangedPassStillSkips() {
        let context = SNTranscriptHostRenderContext()
        let msgs = [makeMessage(id: "a", text: "hi")]

        let openVersion = context.contentVersion(afterSyncing: msgs, showAuthors: false, peerName: "Peer")
        sync(context, msgs: msgs)

        let idleVersion = context.contentVersion(afterSyncing: msgs, showAuthors: false, peerName: "Peer")
        sync(context, msgs: msgs)
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
}

#endif
