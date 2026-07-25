//
// SonarReactionMessageTests.swift
// bitchatTests
//
// ⚡REACT codec + transcript-fold semantics. Must stay byte-identical to the
// Compose `ReactionLine`/`foldMeshReactions` (SonarReactionsTest.kt) so the
// platforms never diverge on a peer-crafted line.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import Sonar

struct SonarReactionMessageTests {

    private let me = PeerID(str: "aaaaaaaaaaaaaaaa")
    private let peer = PeerID(str: "bbbbbbbbbbbbbbbb")

    private func msg(
        _ id: String,
        _ content: String,
        mine: Bool = false,
        status: DeliveryStatus? = nil,
        at seconds: TimeInterval = 1
    ) -> BitchatMessage {
        BitchatMessage(
            id: id,
            sender: mine ? "me" : "peer",
            content: content,
            timestamp: Date(timeIntervalSince1970: seconds),
            isRelay: false,
            isPrivate: true,
            senderPeerID: mine ? me : peer,
            deliveryStatus: status
        )
    }

    // MARK: - Codec

    @Test func decodeRoundTripsAddAndRemove() {
        let add = SonarReactionMessage.add(targetId: "a1b2c3d4", emoji: "👍")
        #expect(SonarReactionMessage.decode(add.encoded()) == add)
        let remove = SonarReactionMessage.remove(targetId: "A1B2-C3D4", emoji: "❤️")
        #expect(SonarReactionMessage.decode(remove.encoded()) == remove)
    }

    @Test func decodeRejectsMalformedLines() {
        #expect(SonarReactionMessage.decode("hello") == nil)
        #expect(SonarReactionMessage.decode("⚡REACT|2|abc|👍|add") == nil, "unknown version")
        #expect(SonarReactionMessage.decode("⚡REACT|1|abc|👍|maybe") == nil, "unknown verb")
        #expect(SonarReactionMessage.decode("⚡REACT|1|abc|👍") == nil, "missing field")
        #expect(SonarReactionMessage.decode("⚡REACT|1|abc|👍|add|extra") == nil, "extra field")
        #expect(SonarReactionMessage.decode("⚡REACT|1||👍|add") == nil, "empty target")
        #expect(SonarReactionMessage.decode("⚡REACT|1|abc||remove") == nil, "empty emoji (both verbs)")
        #expect(SonarReactionMessage.decode("⚡REACT|1|echo-a1b2|👍|add") == nil, "non-hex target (pending echo)")
        #expect(SonarReactionMessage.decode("⚡REACT|1|٩٩٩|👍|add") == nil, "unicode digits (Kotlin rejects too)")
        #expect(SonarReactionMessage.decode("⚡REACT|1|\(String(repeating: "a", count: 65))|👍|add") == nil, "target too long")
        #expect(SonarReactionMessage.decode("⚡REACT|1|abc|this is not an emoji at all!!|add") == nil, "emoji too long")
    }

    // MARK: - Fold

    @Test func foldAggregatesAndHidesLines() {
        let visible = SonarReactionMessage.fold([
            msg("aa11", "hello"),
            msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded(), mine: true),
            msg("r2", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded()),
        ], myPeerID: me)
        #expect(visible.count == 1, "reaction lines never render as rows")
        #expect(visible[0].reactions == [MessageReaction(emoji: "👍", count: 2, mine: true)])
    }

    @Test func foldIsLastWriteWinsPerSenderAndReplaceIsOneSlot() {
        let visible = SonarReactionMessage.fold([
            msg("aa11", "hello"),
            msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded()),
            msg("r2", SonarReactionMessage.add(targetId: "aa11", emoji: "❤️").encoded()),
        ], myPeerID: me)
        #expect(visible[0].reactions == [MessageReaction(emoji: "❤️", count: 1, mine: false)])
    }

    @Test func staleRemoveNeverWipesANewerReplacement() {
        let visible = SonarReactionMessage.fold([
            msg("aa11", "hello"),
            msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "❤️").encoded()),
            msg("r2", SonarReactionMessage.remove(targetId: "aa11", emoji: "👍").encoded()),
        ], myPeerID: me)
        #expect(visible[0].reactions == [MessageReaction(emoji: "❤️", count: 1, mine: false)])
    }

    @Test func removeClearsOwnEmoji() {
        let visible = SonarReactionMessage.fold([
            msg("aa11", "hello"),
            msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded(), mine: true),
            msg("r2", SonarReactionMessage.remove(targetId: "aa11", emoji: "👍").encoded(), mine: true),
        ], myPeerID: me)
        #expect(visible[0].reactions.isEmpty)
    }

    @Test func failedLocalSendDoesNotFoldButIsStillHidden() {
        let visible = SonarReactionMessage.fold([
            msg("aa11", "hello"),
            msg(
                "r1",
                SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded(),
                mine: true,
                status: .failed(reason: "unreachable")
            ),
        ], myPeerID: me)
        #expect(visible.count == 1, "failed line still never renders as a row")
        #expect(visible[0].reactions.isEmpty, "a chip for an undelivered reaction would lie")
    }

    @Test func staleChipClearsWhenAllLinesDisappear() {
        // BitchatMessage is a class: a prior fold mutated `reactions` on the
        // shared instance. A later fold whose input no longer contains the
        // reaction line (blocked sender / removed fallback group / window)
        // must clear the stale chip.
        let target = msg("aa11", "hello")
        _ = SonarReactionMessage.fold([
            target,
            msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded()),
        ], myPeerID: me)
        #expect(!target.reactions.isEmpty)
        let visible = SonarReactionMessage.fold([target], myPeerID: me)
        #expect(visible[0].reactions.isEmpty, "stale aggregate must clear")
    }

    @Test func externalLinesFoldCrossLegWithMyMeshSlot() {
        // My toggle carried over the Marmot fallback leg must share the "me"
        // slot with my mesh lines (one reaction per person, either transport).
        let visible = SonarReactionMessage.fold(
            [
                msg("aa11", "hello"),
                msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded(), mine: true),
            ],
            myPeerID: me,
            externalLines: [
                .init(
                    date: Date(timeIntervalSince1970: 2),
                    line: .add(targetId: "aa11", emoji: "❤️"),
                    mine: true,
                    senderKey: "npub1me"
                )
            ]
        )
        #expect(visible[0].reactions == [MessageReaction(emoji: "❤️", count: 1, mine: true)])
    }

    @Test func myCurrentReactionDrivesToggleSemantics() {
        let transcript = [
            msg("aa11", "hello"),
            msg("r1", SonarReactionMessage.add(targetId: "aa11", emoji: "👍").encoded(), mine: true),
        ]
        #expect(SonarReactionMessage.myCurrentReaction(in: transcript, targetId: "aa11", myPeerID: me) == "👍")
        #expect(SonarReactionMessage.myCurrentReaction(in: transcript, targetId: "dead", myPeerID: me) == nil)
    }
}
