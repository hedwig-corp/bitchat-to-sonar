//
// MarmotReplyChipTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

/// Core resolves a reply's quote chip across the chat's folded groups; the
/// app only words it and names the author.
struct MarmotReplyChipTests {
    private func reply(
        parentMine: Bool = false,
        preview: String? = nil,
        chip: MarmotService.ConversationPreview
    ) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: "child",
            senderNpub: "npub1sender",
            content: "works for me",
            createdAt: Date(timeIntervalSince1970: 100),
            isMine: true,
            media: [],
            reply: MarmotService.MarmotReplyRef(
                parentId: "parent-in-the-other-group",
                parentNpub: "npub1sara",
                preview: preview,
                parentMine: parentMine,
                chip: chip
            )
        )
    }

    /// The parent sits in the twin group, so this group's rows cannot name it.
    @Test
    func aChipFromCoreRendersWithoutTheParentInThisGroup() {
        let ref = snReplyRef(
            from: reply(chip: .text("see you at noon")),
            parents: [],
            counterpartName: "Sara"
        )
        #expect(ref?.preview == "see you at noon")
        #expect(ref?.author == "Sara", "named from the 1:1, not left blank")
    }

    @Test
    func aQuoteOfOurOwnMessageIsYouEvenWhenItIsNotLoaded() {
        let ref = snReplyRef(from: reply(parentMine: true, chip: .photos(2)), counterpartName: "Sara")
        #expect(ref?.author == "You")
        #expect(ref?.preview == "Photo")
    }

    @Test
    func protocolParentsNeverShowTheirRawLine() {
        #expect(snReplyChipText(.nudge) == "Message")
        #expect(snReplyChipText(.voiceCall) == "Message")
        #expect(snReplyChipText(.empty) == nil, "empty: resolve locally, as before")
    }

    /// Without a core chip (mesh replies, older snapshots) the local path still runs.
    @Test
    func anEmptyChipFallsBackToTheSnapshot() {
        let ref = snReplyRef(from: reply(preview: "quoted text", chip: .empty))
        #expect(ref?.preview == "quoted text")
    }
}
