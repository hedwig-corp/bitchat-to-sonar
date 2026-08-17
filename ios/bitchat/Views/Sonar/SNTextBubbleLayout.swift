//
// SNTextBubbleLayout.swift
// bitchat
//
// Signal `CVComponentState` + `CVCellMeasurement` parity for the common text
// row: everything the cell paints is derived ONCE into an immutable model, and
// every frame in the row is computed by pure math that the cell reuses at
// `layoutSubviews`. Measure and render therefore cannot disagree, and neither
// path instantiates a SwiftUI graph while the collection view is scrolling.
//

#if os(iOS)
import Foundation
import SwiftUI
import UIKit

// MARK: - Paint tokens

/// Dynamic `UIColor` for a theme `Color`. Sonar theme colors are UIColor-backed
/// dynamic providers, so light/dark still resolves per trait collection; the
/// alpha overlay has to rebuild the provider rather than resolve it early.
func snUIColor(_ color: Color, alpha: CGFloat = 1) -> UIColor {
    let base = UIColor(color)
    guard alpha < 1 else { return base }
    return UIColor { traits in
        base.resolvedColor(with: traits).withAlphaComponent(alpha)
    }
}

/// Literals the SwiftUI bubble renders verbatim, kept in one place so measure
/// and cell can never drift apart.
enum SNTextBubbleStrings {
    static let retry = "Retry"
    static var showMore: String { String(localized: "content.message.show_more") }
    static var showLess: String { String(localized: "content.message.show_less") }
}

enum SNTextBubbleFont {
    static let body = UIFont.systemFont(ofSize: 16)
    static let mention = UIFont.systemFont(ofSize: 16, weight: .semibold)
    static let author = UIFont.systemFont(ofSize: 12, weight: .bold)
    static let meta = UIFont.systemFont(ofSize: 10.5)
    static let quoteAuthor = UIFont.systemFont(ofSize: 11.5, weight: .heavy)
    static let quotePreview = UIFont.systemFont(ofSize: 12.5)
    static let showMore = UIFont.systemFont(ofSize: 12, weight: .semibold)
    static let state = UIFont.systemFont(ofSize: 11)
    static let retry = UIFont.systemFont(ofSize: 11, weight: .bold)
}

/// Every constant here is transcribed from the SwiftUI `SNMsgBubble` /
/// `SNQuoteChip` / `SNCollectionHostMessageRow` it replaces — keep them in sync
/// when either side moves, or bubbles change size between the two paths.
enum SNTextBubbleMetric {
    static let bubbleWidthFraction: CGFloat = 0.78
    static let rowTopPad: CGFloat = 2
    static let bubbleTopGapContinuation: CGFloat = 2
    static let bubbleTopGap: CGFloat = 9
    static let authorLeadingPad: CGFloat = 12
    static let authorBottomPad: CGFloat = 3
    static let bubblePadTop: CGFloat = 8
    static let bubblePadBottom: CGFloat = 9
    static let bubblePadLeading: CGFloat = 12
    static let bubblePadTrailing: CGFloat = 12
    static let textMetaSpacing: CGFloat = 8
    static let quoteBodySpacing: CGFloat = 6
    static let quoteTopPad: CGFloat = 2
    static let quotePadTop: CGFloat = 5
    static let quotePadBottom: CGFloat = 6
    static let quotePadLeading: CGFloat = 12
    static let quotePadTrailing: CGFloat = 9
    static let quoteLineSpacing: CGFloat = 1
    static let quoteStripeWidth: CGFloat = 3
    static let quoteCornerRadius: CGFloat = 9
    static let metaIconSize: CGFloat = 11
    static let metaIconSpacing: CGFloat = 3
    static let metaBottomPad: CGFloat = 1.5
    static let showMoreMinSide: CGFloat = 44
    static let showMoreHorizontalPad: CGFloat = 6
    static let stateTopPad: CGFloat = 3
    static let stateHorizontalPad: CGFloat = 4
    static let stateIconSize: CGFloat = 11
    static let stateSpacing: CGFloat = 3
    static let retryPadHorizontal: CGFloat = 7
    static let retryPadVertical: CGFloat = 7
    static let bubbleRadius: CGFloat = SonarTheme.bubbleRadius
    static let bubbleTailRadius: CGFloat = SonarTheme.bubbleRadius * 0.28
    static let bodyLineSpacing: CGFloat = 16 * 0.2
    /// Beyond this an unbroken run cannot wrap on word boundaries, so the
    /// paragraph switches to character wrapping instead of overflowing.
    static let longTokenThreshold = 30
}

// MARK: - Render model

/// Immutable, pre-derived paint state for one text row. Built off the scroll
/// path and cached by `(message id, height key)`.
struct SNTextBubbleModel {
    struct Quote {
        let parentId: String
        let author: String?
        let preview: String
        let stripeColor: UIColor
        let fillColor: UIColor
        let authorColor: UIColor
        let previewColor: UIColor
    }

    struct StateFooter {
        let text: String
        let isPending: Bool
        let isFailed: Bool
        let canRetry: Bool
        let color: UIColor
    }

    let id: String
    let mine: Bool
    let isContinuation: Bool
    let author: String?
    let authorColor: UIColor
    let authorTappable: Bool
    let text: NSAttributedString
    /// Precomputed so the cell never scans attributes to decide whether it
    /// needs a TextKit hit-tester.
    let hasLinks: Bool
    let usesCharacterWrapping: Bool
    let time: String
    let via: SNVia?
    let quote: Quote?
    let isTruncated: Bool
    let isExpanded: Bool
    let state: StateFooter?
    let canSwipeReply: Bool
    let canReply: Bool
    let copyText: String?
    let bubbleFill: UIColor
    let bubbleInk: UIColor
    let metaColor: UIColor
    let dropsShadow: Bool
    let accessibilityText: String
    /// Identity of everything that can change size or paint — the cell's cache
    /// key and the collection host's height key both derive from it.
    let measurementKey: String
}

extension SNTextBubbleModel {
    /// True when the row is a plain text bubble, i.e. the kind this UIKit cell
    /// replaces. Everything else (media, stickers, pay, calls, nudges, action
    /// lines) keeps the SwiftUI hosting path.
    static func handles(_ m: SNMessage) -> Bool {
        m.call == nil && !m.trill && m.pay == nil && m.media.isEmpty
            && m.stickerRef == nil && !m.action
    }

    static func make(
        message m: SNMessage,
        isContinuation: Bool,
        showAuthor: Bool,
        showState: Bool,
        quotedPeerName: String?,
        isExpanded: Bool,
        authorTappable: Bool,
        measurementKey: String
    ) -> SNTextBubbleModel {
        let ink: UIColor = m.mine
            ? snUIColor(m.via == .internet ? SonarTheme.onNet : SonarTheme.onAccent)
            : snUIColor(SonarTheme.text)
        let fill: UIColor = m.mine
            ? snUIColor(m.via == .internet ? SonarTheme.netFill : SonarTheme.accentFill)
            : snUIColor(SonarTheme.bubbleOther)
        let metaColor: UIColor = m.mine
            ? snUIColor(m.via == .internet ? SonarTheme.onNet : SonarTheme.onAccent,
                        alpha: m.via == .internet ? 0.75 : 0.72)
            : snUIColor(SonarTheme.text3)

        let preview = SonarTranscriptDisplayPolicy.preview(m.text)
        let visibleText = isExpanded ? m.text : preview.text
        // Mention spans are offsets into the FULL text; a collapsed preview is
        // trimmed as well as cut, so styling it would land on wrong characters.
        let renderableMentions: [SNResolvedMention] =
            (!m.mentions.isEmpty && visibleText == m.text) ? m.mentions.mentions : []
        let mentionColor: UIColor = (m.mentions.mentionsMe && !m.mine)
            ? snUIColor(SonarTheme.accentDeep)
            : ink
        let usesCharacterWrapping = visibleText.hasVeryLongToken(
            threshold: SNTextBubbleMetric.longTokenThreshold
        )
        let attributed = SonarMessageTextFormatter.nsAttributedBubbleText(
            visibleText,
            font: SNTextBubbleFont.body,
            baseColor: ink,
            lineSpacing: SNTextBubbleMetric.bodyLineSpacing,
            lineBreakMode: usesCharacterWrapping ? .byCharWrapping : .byWordWrapping,
            linkColor: m.mine ? ink : snUIColor(SonarTheme.accentDeep),
            mentionFont: renderableMentions.isEmpty ? nil : SNTextBubbleFont.mention,
            mentionColor: renderableMentions.isEmpty ? nil : mentionColor,
            mentions: renderableMentions.isEmpty ? nil : renderableMentions,
            detectBareDomains: true,
            excludeLinkBeforeTrailingEllipsis: preview.isTruncated && !isExpanded
        )

        var quote: Quote?
        if snReplyUIEnabled(), let reply = m.reply {
            let you = String(localized: "chat.reply.you", defaultValue: "You")
            let author = (reply.author == you || quotedPeerName == nil) ? reply.author : quotedPeerName
            let accent = m.via == .internet ? SonarTheme.net : SonarTheme.accent
            let accentDeep = m.via == .internet ? SonarTheme.netDeep : SonarTheme.accentDeep
            quote = Quote(
                parentId: reply.parentId,
                author: author,
                preview: reply.preview,
                stripeColor: m.mine ? snUIColor(m.via == .internet ? SonarTheme.onNet : SonarTheme.onAccent, alpha: 0.85)
                    : snUIColor(accent),
                fillColor: m.mine
                    ? UIColor.white.withAlphaComponent(0.20)
                    : snUIColor(Color(sonarHex: 0x7F8A8E, opacity: 0.16)),
                authorColor: m.mine ? ink : snUIColor(accentDeep),
                previewColor: m.mine
                    ? snUIColor(m.via == .internet ? SonarTheme.onNet : SonarTheme.onAccent, alpha: 0.82)
                    : snUIColor(SonarTheme.text, alpha: 0.82)
            )
        }

        var state: StateFooter?
        if showState, let stateText = m.state {
            let isFailed = stateText == "Couldn't send"
            state = StateFooter(
                text: "\(stateText) · \(m.via?.label ?? "")",
                isPending: stateText == "Sending" || stateText == "Uploading",
                isFailed: isFailed,
                canRetry: snCanRetryFailedMessage(m),
                color: isFailed ? snUIColor(SonarTheme.danger) : snUIColor(SonarTheme.text3)
            )
        }

        return SNTextBubbleModel(
            id: m.id,
            mine: m.mine,
            isContinuation: isContinuation,
            author: showAuthor ? m.author : nil,
            authorColor: snUIColor(SonarTheme.authorColor(m.author ?? "")),
            authorTappable: authorTappable && !m.mine,
            text: attributed,
            hasLinks: attributed.snContainsLink,
            usesCharacterWrapping: usesCharacterWrapping,
            time: m.time,
            via: m.via,
            quote: quote,
            isTruncated: preview.isTruncated,
            isExpanded: isExpanded,
            state: state,
            canSwipeReply: snCanReply(to: m),
            canReply: snCanReply(to: m),
            copyText: snCopyableText(of: m),
            bubbleFill: fill,
            bubbleInk: ink,
            metaColor: metaColor,
            dropsShadow: !m.mine,
            accessibilityText: visibleText,
            measurementKey: measurementKey
        )
    }
}

/// FNV-1a over UTF-8. Height keys carry message text identity; hashing keeps the
/// key short so the layout pass hashes bounded strings instead of whole
/// messages, and the value is stable across launches unlike `hashValue`.
func snFNV1a(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

extension NSAttributedString {
    /// True when any run carries a `.link` (URL or `SNMentions` deep link).
    var snContainsLink: Bool {
        guard length > 0 else { return false }
        var found = false
        enumerateAttribute(.link, in: NSRange(location: 0, length: length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

// MARK: - Geometry

/// Frames in row (cell content) coordinates. `.null` marks an absent part.
struct SNTextBubbleGeometry {
    var totalHeight: CGFloat = 0
    var authorFrame: CGRect = .null
    var bubbleFrame: CGRect = .null
    var quoteFrame: CGRect = .null
    var textFrame: CGRect = .null
    var metaFrame: CGRect = .null
    var showMoreFrame: CGRect = .null
    var stateFrame: CGRect = .null
}

enum SNTextBubbleLayout {
    static func geometry(
        model: SNTextBubbleModel,
        columnWidth: CGFloat,
        leftToRight: Bool = true
    ) -> SNTextBubbleGeometry {
        let column = max(1, columnWidth)
        let maxBubble = column * SNTextBubbleMetric.bubbleWidthFraction
        let hPad = SNTextBubbleMetric.bubblePadLeading + SNTextBubbleMetric.bubblePadTrailing

        let timeSize = size(model.time, font: SNTextBubbleFont.meta)
        var metaWidth = timeSize.width
        if model.via != nil {
            metaWidth += SNTextBubbleMetric.metaIconSpacing + SNTextBubbleMetric.metaIconSize
        }
        let metaHeight = max(timeSize.height, model.via == nil ? 0 : SNTextBubbleMetric.metaIconSize)
            + SNTextBubbleMetric.metaBottomPad

        let textAvailable = max(1, maxBubble - hPad - SNTextBubbleMetric.textMetaSpacing - metaWidth)
        let textSize = size(model.text, maxWidth: textAvailable)

        var contentWidth = textSize.width + SNTextBubbleMetric.textMetaSpacing + metaWidth
        var quoteHeight: CGFloat = 0
        if let quote = model.quote {
            let previewWidth = size(quote.preview, font: SNTextBubbleFont.quotePreview).width
            let authorWidth = quote.author.map { size($0, font: SNTextBubbleFont.quoteAuthor).width } ?? 0
            let ideal = max(previewWidth, authorWidth)
                + SNTextBubbleMetric.quotePadLeading + SNTextBubbleMetric.quotePadTrailing
            contentWidth = max(contentWidth, min(maxBubble - hPad, ideal))
            let authorHeight = quote.author.map { _ in
                ceil(SNTextBubbleFont.quoteAuthor.lineHeight) + SNTextBubbleMetric.quoteLineSpacing
            } ?? 0
            quoteHeight = SNTextBubbleMetric.quoteTopPad
                + SNTextBubbleMetric.quotePadTop
                + authorHeight
                + ceil(SNTextBubbleFont.quotePreview.lineHeight)
                + SNTextBubbleMetric.quotePadBottom
        }
        let bubbleWidth = min(maxBubble, contentWidth + hPad)
        let contentRowHeight = max(textSize.height, metaHeight)
        let bubbleHeight = SNTextBubbleMetric.bubblePadTop
            + (model.quote == nil ? 0 : quoteHeight + SNTextBubbleMetric.quoteBodySpacing)
            + contentRowHeight
            + SNTextBubbleMetric.bubblePadBottom

        var authorBlockHeight: CGFloat = 0
        var authorSize = CGSize.zero
        if let author = model.author {
            authorSize = size(author, font: SNTextBubbleFont.author)
            authorBlockHeight = authorSize.height + SNTextBubbleMetric.authorBottomPad
        }

        var showMoreSize = CGSize.zero
        if model.isTruncated {
            let label = model.isExpanded ? SNTextBubbleStrings.showLess : SNTextBubbleStrings.showMore
            let text = size(label, font: SNTextBubbleFont.showMore)
            showMoreSize = CGSize(
                width: max(SNTextBubbleMetric.showMoreMinSide, text.width + SNTextBubbleMetric.showMoreHorizontalPad * 2),
                height: SNTextBubbleMetric.showMoreMinSide
            )
        }

        var stateSize = CGSize.zero
        if let state = model.state {
            let text = size(state.text, font: SNTextBubbleFont.state)
            var width = SNTextBubbleMetric.stateIconSize + SNTextBubbleMetric.stateSpacing + text.width
            var height = max(SNTextBubbleMetric.stateIconSize, text.height)
            if state.isFailed, state.canRetry {
                let retry = size(SNTextBubbleStrings.retry, font: SNTextBubbleFont.retry)
                width += SNTextBubbleMetric.stateSpacing + retry.width + SNTextBubbleMetric.retryPadHorizontal * 2
                height = max(height, retry.height + SNTextBubbleMetric.retryPadVertical * 2)
            }
            stateSize = CGSize(
                width: width + SNTextBubbleMetric.stateHorizontalPad * 2,
                height: height + SNTextBubbleMetric.stateTopPad
            )
        }

        let blockWidth = max(bubbleWidth, max(showMoreSize.width, stateSize.width))
        let blockX = model.mine == leftToRight ? column - blockWidth : 0
        var g = SNTextBubbleGeometry()
        var y = SNTextBubbleMetric.rowTopPad
            + (model.isContinuation ? SNTextBubbleMetric.bubbleTopGapContinuation : SNTextBubbleMetric.bubbleTopGap)

        if model.author != nil {
            let x = leftToRight
                ? blockX + SNTextBubbleMetric.authorLeadingPad
                : blockX + blockWidth - SNTextBubbleMetric.authorLeadingPad - authorSize.width
            g.authorFrame = CGRect(origin: CGPoint(x: x, y: y), size: authorSize)
            y += authorBlockHeight
        }

        let bubbleX = model.mine == leftToRight ? blockX + blockWidth - bubbleWidth : blockX
        g.bubbleFrame = CGRect(x: bubbleX, y: y, width: bubbleWidth, height: bubbleHeight)

        var innerY = y + SNTextBubbleMetric.bubblePadTop
        let innerX = leftToRight
            ? bubbleX + SNTextBubbleMetric.bubblePadLeading
            : bubbleX + SNTextBubbleMetric.bubblePadTrailing
        let innerWidth = bubbleWidth - hPad
        if model.quote != nil {
            g.quoteFrame = CGRect(
                x: innerX,
                y: innerY + SNTextBubbleMetric.quoteTopPad,
                width: innerWidth,
                height: quoteHeight - SNTextBubbleMetric.quoteTopPad
            )
            innerY += quoteHeight + SNTextBubbleMetric.quoteBodySpacing
        }
        let textX = leftToRight ? innerX : innerX + innerWidth - textSize.width
        g.textFrame = CGRect(
            x: textX,
            y: innerY + max(0, contentRowHeight - textSize.height),
            width: textSize.width,
            height: textSize.height
        )
        let metaX = leftToRight
            ? innerX + innerWidth - metaWidth
            : innerX
        g.metaFrame = CGRect(
            x: metaX,
            y: innerY + max(0, contentRowHeight - metaHeight),
            width: metaWidth,
            height: metaHeight - SNTextBubbleMetric.metaBottomPad
        )
        y += bubbleHeight

        if model.isTruncated {
            let x = model.mine == leftToRight ? blockX + blockWidth - showMoreSize.width : blockX
            g.showMoreFrame = CGRect(origin: CGPoint(x: x, y: y), size: showMoreSize)
            y += showMoreSize.height
        }
        if model.state != nil {
            let x = model.mine == leftToRight ? blockX + blockWidth - stateSize.width : blockX
            g.stateFrame = CGRect(
                x: x,
                y: y + SNTextBubbleMetric.stateTopPad,
                width: stateSize.width,
                height: stateSize.height - SNTextBubbleMetric.stateTopPad
            )
            y += stateSize.height
        }

        g.totalHeight = ceil(y)
        return g
    }

    static func height(model: SNTextBubbleModel, columnWidth: CGFloat) -> CGFloat {
        geometry(model: model, columnWidth: columnWidth).totalHeight
    }

    static func size(_ attributed: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        guard attributed.length > 0 else { return CGSize(width: 0, height: ceil(SNTextBubbleFont.body.lineHeight)) }
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: min(maxWidth, ceil(bounds.width)), height: ceil(bounds.height))
    }

    static func size(_ text: String, font: UIFont) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}

// MARK: - Measurement cache (Signal CVCellMeasurementCache)

/// Bounded `(measurement key, width)` → geometry cache. One measure per row per
/// width serves both the layout pass and the cell, so scrolling re-uses frames
/// instead of re-deriving them.
@MainActor
final class SNTextBubbleMeasurementCache {
    static let shared = SNTextBubbleMeasurementCache()
    static let limit = 600

    private var map: [String: SNTextBubbleGeometry] = [:]
    private var order: [String] = []

    func geometry(
        model: SNTextBubbleModel,
        columnWidth: CGFloat,
        leftToRight: Bool
    ) -> SNTextBubbleGeometry {
        let key = "\(model.measurementKey)|\(Int(columnWidth.rounded()))|\(leftToRight ? 1 : 0)"
        if let hit = map[key] { return hit }
        let geometry = SNTextBubbleLayout.geometry(
            model: model,
            columnWidth: columnWidth,
            leftToRight: leftToRight
        )
        map[key] = geometry
        order.append(key)
        if order.count > Self.limit {
            let evicted = order.removeFirst()
            map.removeValue(forKey: evicted)
        }
        return geometry
    }

    func clear() {
        map.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
#endif
