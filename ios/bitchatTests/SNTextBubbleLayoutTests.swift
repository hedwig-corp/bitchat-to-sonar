//
// SNTextBubbleLayoutTests.swift
// bitchatTests
//
// Pre-measured UIKit text rows (R-044). The cell lays itself out from the SAME
// geometry the collection host measures with, so these tests pin the geometry
// contract: heights react to the parts that are actually painted, and every
// painted frame stays inside the row the layout claimed.
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Sonar

@MainActor
struct SNTextBubbleLayoutTests {
    private let column: CGFloat = 393 - 28

    private func message(
        id: String = "m1",
        text: String = "hello there",
        mine: Bool = false,
        state: String? = nil,
        reply: SNReplyRef? = nil,
        author: String? = nil
    ) -> SNMessage {
        SNMessage(
            id: id,
            mine: mine,
            author: author,
            text: text,
            time: "12:34",
            via: .internet,
            state: state,
            reply: reply
        )
    }

    private func model(
        _ m: SNMessage,
        cont: Bool = false,
        showAuthor: Bool = false,
        showState: Bool = false,
        expanded: Bool = false
    ) -> SNTextBubbleModel {
        SNTextBubbleModel.make(
            message: m,
            isContinuation: cont,
            showAuthor: showAuthor,
            showState: showState,
            quotedPeerName: nil,
            isExpanded: expanded,
            authorTappable: true,
            measurementKey: "k|\(m.id)|\(cont)|\(showAuthor)|\(showState)|\(expanded)"
        )
    }

    // MARK: Routing

    @Test
    func handlesOnlyPlainTextRows() {
        #expect(SNTextBubbleModel.handles(message()))
        var media = message()
        media.media = [SNMediaItem(url: "https://x/y", mime: "image/png", filename: "y.png", groupId: "g")]
        #expect(!SNTextBubbleModel.handles(media))
        var action = message()
        action.action = true
        #expect(!SNTextBubbleModel.handles(action))
        var trill = message()
        trill.trill = true
        #expect(!SNTextBubbleModel.handles(trill))
        var pay = message()
        pay.pay = SNPayInfo(id: "p", sats: 21, state: .claimed)
        #expect(!SNTextBubbleModel.handles(pay))
    }

    // MARK: Heights

    @Test
    func tallerTextMakesTallerRow() {
        let short = SNTextBubbleLayout.height(model: model(message(text: "hi")), columnWidth: column)
        let long = SNTextBubbleLayout.height(
            model: model(message(text: String(repeating: "wrap this line ", count: 20))),
            columnWidth: column
        )
        #expect(long > short)
    }

    @Test
    func narrowerColumnWrapsToTallerRow() {
        let m = model(message(text: String(repeating: "some words here ", count: 8)))
        let wide = SNTextBubbleLayout.height(model: m, columnWidth: column)
        let narrow = SNTextBubbleLayout.height(model: m, columnWidth: 200)
        #expect(narrow > wide)
    }

    @Test
    func continuationRowIsShorterByTheGapDifference() {
        let m = message(text: "hi")
        let normal = SNTextBubbleLayout.height(model: model(m), columnWidth: column)
        let cont = SNTextBubbleLayout.height(model: model(m, cont: true), columnWidth: column)
        #expect(normal - cont == SNTextBubbleMetric.bubbleTopGap - SNTextBubbleMetric.bubbleTopGapContinuation)
    }

    @Test
    func quoteAuthorAndStateFooterEachAddHeight() {
        let plain = SNTextBubbleLayout.height(model: model(message(text: "hi")), columnWidth: column)
        let quoted = SNTextBubbleLayout.height(
            model: model(message(
                text: "hi",
                reply: SNReplyRef(parentId: "p1", parentNpub: nil, author: "Ada", preview: "earlier")
            )),
            columnWidth: column
        )
        #expect(quoted > plain)

        let withAuthor = SNTextBubbleLayout.height(
            model: model(message(text: "hi", author: "Ada"), showAuthor: true),
            columnWidth: column
        )
        #expect(withAuthor > plain)

        let withState = SNTextBubbleLayout.height(
            model: model(message(text: "hi", mine: true, state: "Couldn't send"), showState: true),
            columnWidth: column
        )
        #expect(withState > plain)
    }

    @Test
    func expandingATruncatedRowGrowsIt() {
        let long = message(text: String(repeating: "x", count: 4000))
        let collapsed = model(long)
        #expect(collapsed.isTruncated)
        let expanded = model(long, expanded: true)
        #expect(
            SNTextBubbleLayout.height(model: expanded, columnWidth: column)
                > SNTextBubbleLayout.height(model: collapsed, columnWidth: column)
        )
    }

    // MARK: Frames

    @Test
    func paintedFramesStayInsideTheMeasuredRow() {
        let m = model(message(
            text: String(repeating: "measure me ", count: 6),
            mine: true,
            state: "Sending",
            reply: SNReplyRef(parentId: "p", parentNpub: nil, author: "Ada", preview: "earlier")
        ), showState: true)
        let g = SNTextBubbleLayout.geometry(model: m, columnWidth: column)
        let row = CGRect(x: 0, y: 0, width: column, height: g.totalHeight)
        for frame in [g.bubbleFrame, g.quoteFrame, g.textFrame, g.metaFrame, g.stateFrame] where !frame.isNull {
            #expect(row.contains(frame.integral) || row.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        }
        // Text and meta live inside the bubble, and meta sits after the text.
        #expect(g.bubbleFrame.contains(g.textFrame.insetBy(dx: 0.5, dy: 0.5)))
        #expect(g.metaFrame.minX >= g.textFrame.maxX - 1)
    }

    @Test
    func outgoingRowsHugTheTrailingEdgeAndIncomingTheLeading() {
        let mine = SNTextBubbleLayout.geometry(model: model(message(text: "hi", mine: true)), columnWidth: column)
        #expect(abs(mine.bubbleFrame.maxX - column) < 0.5)
        let theirs = SNTextBubbleLayout.geometry(model: model(message(text: "hi")), columnWidth: column)
        #expect(abs(theirs.bubbleFrame.minX) < 0.5)
    }

    @Test
    func bubbleNeverExceedsTheWidthCap() {
        let g = SNTextBubbleLayout.geometry(
            model: model(message(text: String(repeating: "long ", count: 200))),
            columnWidth: column
        )
        #expect(g.bubbleFrame.width <= column * SNTextBubbleMetric.bubbleWidthFraction + 0.5)
    }

    // MARK: Derived paint state

    @Test
    func linksAndMentionsAreDetectedOnceIntoTheModel() {
        #expect(model(message(text: "see https://example.com now")).hasLinks)
        #expect(!model(message(text: "no links here")).hasLinks)
    }

    @Test
    func mentionChipsMatchSwiftUIDesignAndBarCallsOutSelf() {
        let text = "hey @alice"
        // UTF-16: "hey " = 4, "@alice" = 6 → [4, 10).
        let span = SNMentionSpan(start: 4, end: 10, name: "alice", suffixHex4: nil)
        let resolved = SNResolvedMention(span: span, npub: "npub1alice")

        var incoming = message(text: text)
        incoming.mentions = SNMentionInfo(mentions: [resolved], mentionsMe: true)
        let tagged = model(incoming)
        #expect(tagged.mentionBarColor != nil)
        var hasChipBackground = false
        tagged.text.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: tagged.text.length)
        ) { value, range, stop in
            if value != nil {
                hasChipBackground = range == span.nsRange
                stop.pointee = true
            }
        }
        #expect(hasChipBackground)

        var mine = message(text: text, mine: true)
        mine.mentions = SNMentionInfo(mentions: [resolved], mentionsMe: false)
        #expect(model(mine).mentionBarColor == nil)

        var other = message(text: text)
        other.mentions = SNMentionInfo(mentions: [resolved], mentionsMe: false)
        let notTagged = model(other)
        #expect(notTagged.mentionBarColor == nil)
        var otherHasChip = false
        notTagged.text.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: notTagged.text.length)
        ) { value, _, stop in
            if value != nil {
                otherHasChip = true
                stop.pointee = true
            }
        }
        #expect(otherHasChip)
    }

    /// The UIKit row replaces a SwiftUI row that is still used for rich kinds
    /// and on macOS. Heights must stay close, or the same chat changes shape
    /// depending on which path rendered it.
    @Test(arguments: [
        "hi",
        "a slightly longer single line message",
        String(repeating: "wrapping across several lines ", count: 4),
    ])
    func heightStaysCloseToTheSwiftUIRow(text: String) {
        let m = message(text: text)
        let uikit = SNTextBubbleLayout.height(model: model(m), columnWidth: column)
        let host = UIHostingController(rootView: AnyView(
            SNCollectionHostMessageRow(
                message: m,
                cont: false,
                showAuthor: false,
                showState: false,
                peerName: "Peer",
                money: { _ in "" },
                fiatText: { _ in nil },
                onTapAuthor: nil,
                mediaPipeline: .unavailable,
                loadSticker: nil,
                onTapPack: nil,
                onRetry: nil,
                onCancelUpload: nil,
                uploadProgressSource: nil,
                columnWidth: column,
                expandedMessageIDs: [],
                onExpandedChange: { _ in }
            )
            .padding(.horizontal, 14)
        ))
        let swiftUI = host.sizeThatFits(
            in: CGSize(width: column + 28, height: .greatestFiniteMagnitude)
        ).height
        let delta = uikit - swiftUI
        #expect(abs(delta) <= 6, "uikit=\(uikit) swiftui=\(swiftUI) delta=\(delta)")
    }

    @Test
    func measurementCacheReturnsTheSameGeometry() {
        let m = model(message(text: "cache me"))
        let cache = SNTextBubbleMeasurementCache.shared
        cache.clear()
        let first = cache.geometry(model: m, columnWidth: column, leftToRight: true)
        let second = cache.geometry(model: m, columnWidth: column, leftToRight: true)
        #expect(first.totalHeight == second.totalHeight)
        #expect(first.bubbleFrame == second.bubbleFrame)
        cache.clear()
    }
}
#endif
