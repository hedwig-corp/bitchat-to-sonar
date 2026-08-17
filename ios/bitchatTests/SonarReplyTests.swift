import Foundation
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#endif
@testable import Sonar

struct SonarReplyTests {
    @Test @MainActor
    func quoteBubbleDoesNotInheritTranscriptViewportHeight() {
        #if os(iOS)
        let reply = SNReplyRef(
            parentId: String(repeating: "ab", count: 32),
            parentNpub: "npub1peer",
            author: "Vincenzo-Mac",
            preview: "https://router.hedwig.sh"
        )
        let view = SNFillWidestVStack(spacing: 6) {
            SNQuoteChip(reply: reply, mine: true, ink: SonarTheme.onNet)
            HStack(spacing: 8) {
                Text("Thanks this works")
                Text("19:46")
            }
        }
        .frame(width: 260)

        let host = UIHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: 260, height: 640))

        #expect(size.height > 40)
        #expect(size.height < 120)
        #endif
    }

    @Test @MainActor
    func replyComposerDoesNotInheritTranscriptViewportHeight() {
        #if os(iOS)
        let reply = SNReplyRef(
            parentId: String(repeating: "cd", count: 32),
            parentNpub: "npub1peer",
            author: "Vincenzo-Mac",
            preview: "https://router.hedwig.sh"
        )
        let host = UIHostingController(
            rootView: SNComposerReplyBanner(reply: reply, onCancel: {})
                .frame(width: 390)
        )

        let size = host.sizeThatFits(in: CGSize(width: 390, height: 700))

        #expect(size.height > 40)
        #expect(size.height < 100)
        #endif
    }

    @Test
    func nipC7RequiresEventIdHexAndNpub() {
        let id = String(repeating: "ab", count: 32)
        #expect(snCanEmitNipC7(parentId: id, parentNpub: "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"))
        #expect(!snCanEmitNipC7(parentId: "optimistic-1", parentNpub: "npub1abc"))
        #expect(!snCanEmitNipC7(parentId: id, parentNpub: nil))
        #expect(!snCanEmitNipC7(parentId: id, parentNpub: "hex-not-npub"))
    }

    @Test
    func replyDisabledOnOptimisticAndSendingRows() {
        let live = SNMessage(id: String(repeating: "ab", count: 32), text: "hi", time: "10:00")
        #expect(snCanReply(to: live))
        #expect(!snCanReply(to: SNMessage(id: "optimistic-1", text: "hi", time: "10:00")))
        #expect(!snCanReply(to: SNMessage(id: "failed-1", text: "hi", time: "10:00")))
        var sending = live
        sending.state = "Sending"
        #expect(!snCanReply(to: sending))
    }

    @Test
    func copyUsesFullSourceAndSkipsNonTextRows() {
        let live = SNMessage(id: String(repeating: "ab", count: 32), text: "  hello  ", time: "10:00")
        #expect(snCopyableText(of: live) == "  hello  ")
        #expect(!(snCopyableText(of: live) ?? "").contains(live.time))
        var sending = live
        sending.state = "Sending"
        #expect(snCopyableText(of: sending) == "  hello  ")
        #expect(snCopyableText(of: SNMessage(id: "x", text: "   ", time: "10:00")) == nil)
        var action = live
        action.action = true
        #expect(snCopyableText(of: action) == nil)
        var trill = live
        trill.trill = true
        #expect(snCopyableText(of: trill) == nil)
    }

    @Test
    func duplicateParentRowsDoNotCrashTranscriptHydration() {
        let authors = snReplyParentAuthorsById([
            (id: "same-event", author: "First"),
            (id: "same-event", author: "Duplicate"),
            (id: "other-event", author: "Other"),
        ])

        #expect(authors == [
            "same-event": "First",
            "other-event": "Other",
        ])
    }

    @Test
    func duplicateTranscriptRowsCollapseFirstWinsBeforeRendering() {
        let first = SNMessage(id: "same-event", mine: false, text: "First", time: "12:00")
        let duplicate = SNMessage(id: "same-event", mine: false, text: "Duplicate", time: "12:01")
        let other = SNMessage(id: "other-event", mine: true, text: "Other", time: "12:02")

        let rows = snDeduplicateTranscriptRowsFirstWins([
            (date: Date(timeIntervalSince1970: 1), message: first),
            (date: Date(timeIntervalSince1970: 2), message: duplicate),
            (date: Date(timeIntervalSince1970: 3), message: other),
        ])

        #expect(rows.map(\.message.id) == ["same-event", "other-event"])
        #expect(rows.first?.message.text == "First")
    }

    @Test
    func meshReplyHydratesPreviewFromParentInWindow() {
        let parent = BitchatMessage(
            id: "parent-mid",
            sender: "morningstatic",
            content: "see you at 9",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            isPrivate: true
        )
        let child = BitchatMessage(
            id: "child-mid",
            sender: "me",
            content: "ok",
            timestamp: Date(timeIntervalSince1970: 2),
            isRelay: false,
            isPrivate: true,
            replyTo: "parent-mid"
        )
        let ref = snMeshReplyRef(from: child, parents: [parent])
        #expect(ref?.parentId == "parent-mid")
        #expect(ref?.preview == "see you at 9")
        #expect(ref?.author == "morningstatic")
        let missing = BitchatMessage(
            id: "other",
            sender: "me",
            content: "ok",
            timestamp: Date(timeIntervalSince1970: 3),
            isRelay: false,
            isPrivate: true,
            replyTo: " "
        )
        #expect(snMeshReplyRef(from: missing, parents: [parent]) == nil)
    }
}
