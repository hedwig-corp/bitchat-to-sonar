//
// SonarMessageBubbleView.swift
// bitchat
//
// iMessage-style message bubbles with transport-colored fills:
// own messages are cyan when they travel over the Bluetooth mesh and
// indigo when they travel over Nostr/the internet. Incoming messages use
// the quiet `bubbleOther` surface. A tiny per-message meta row shows the
// time and how the message traveled (mesh vs internet).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarMessageBubbleView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    let message: BitchatMessage
    /// How this message travels (or traveled): drives the bubble color.
    let transport: SonarTransport
    /// Whether to show the author name above incoming bubbles (public channels).
    let showAuthor: Bool
    @Binding var expandedMessageIDs: Set<String>

    private var isSelf: Bool {
        viewModel.isSelfMessage(message)
    }

    private var bubbleTextColor: Color {
        isSelf ? transport.onFill : SonarTheme.text
    }

    private var isLongMessage: Bool {
        let content = message.content
        let hasCashu = !content.extractCashuLinks().isEmpty
        return (content.count > TransportConfig.uiLongMessageLengthThreshold
                || content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold))
            && !hasCashu
    }

    var body: some View {
        if message.sender == "system" {
            systemRow
        } else {
            bubbleRow
        }
    }

    // MARK: - System messages

    private var systemRow: some View {
        HStack {
            Spacer(minLength: 12)
            Text("* \(message.content) *")
                .font(SonarTheme.uiFont(size: 13).italic())
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
            Spacer(minLength: 12)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Chat bubbles

    private var bubbleRow: some View {
        let cashuLinks = message.content.extractCashuLinks()
        let lightningLinks = message.content.extractLightningLinks()
        let isExpanded = expandedMessageIDs.contains(message.id)

        return HStack(alignment: .bottom, spacing: 0) {
            if isSelf { Spacer(minLength: 56) }

            VStack(alignment: isSelf ? .trailing : .leading, spacing: 3) {
                if showAuthor && !isSelf {
                    Text(authorDisplayName)
                        .font(SonarTheme.uiFont(size: 12, weight: .bold))
                        .foregroundColor(viewModel.senderColor(for: message, isDark: colorScheme == .dark))
                        .padding(.leading, 12)
                        .lineLimit(1)
                }

                bubbleBody(isExpanded: isExpanded)

                if isLongMessage {
                    Button(isExpanded
                           ? String(localized: "content.message.show_less")
                           : String(localized: "content.message.show_more")) {
                        if isExpanded { expandedMessageIDs.remove(message.id) }
                        else { expandedMessageIDs.insert(message.id) }
                    }
                    .font(SonarTheme.uiFont(size: 12, weight: .semibold))
                    .foregroundColor(SonarTheme.accentDeep)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                }

                if !lightningLinks.isEmpty || !cashuLinks.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(lightningLinks, id: \.self) { link in
                            PaymentChipView(paymentType: .lightning(link))
                        }
                        ForEach(cashuLinks, id: \.self) { link in
                            PaymentChipView(paymentType: .cashu(link))
                        }
                    }
                    .padding(.top, 2)
                }

                // Delivery state under own private messages, in plain language
                if isSelf, message.isPrivate, let status = message.deliveryStatus {
                    HStack(spacing: 4) {
                        DeliveryStatusView(status: status)
                        Text("via \(transport.label)")
                            .font(SonarTheme.uiFont(size: 11))
                            .foregroundColor(SonarTheme.text3)
                    }
                    .padding(.trailing, 4)
                }
            }

            if !isSelf { Spacer(minLength: 56) }
        }
        .padding(.vertical, 3)
    }

    private func bubbleBody(isExpanded: Bool) -> some View {
        // Text + tiny trailing meta (time + transport icon), iMessage style.
        HStack(alignment: .bottom, spacing: 6) {
            Text(formattedContent)
                .font(SonarTheme.uiFont(size: 16))
                .lineLimit(isLongMessage && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 3) {
                Text(shortTime)
                    .font(SonarTheme.uiFont(size: 10.5))
                Image(systemName: transport.iconName)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(isSelf ? transport.onFill.opacity(0.72) : SonarTheme.text3)
            .padding(.bottom, 1)
            .accessibilityLabel("Sent at \(shortTime) via \(transport.label)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: SonarTheme.bubbleRadius,
                bottomLeadingRadius: isSelf ? SonarTheme.bubbleRadius : SonarTheme.bubbleRadius * 0.28,
                bottomTrailingRadius: isSelf ? SonarTheme.bubbleRadius * 0.28 : SonarTheme.bubbleRadius,
                topTrailingRadius: SonarTheme.bubbleRadius,
                style: .continuous
            )
            .fill(isSelf ? transport.fill : SonarTheme.bubbleOther)
            .shadow(
                color: colorScheme == .dark ? .clear : Color(sonarHex: 0x0A232D, opacity: 0.07),
                radius: 1, y: 1
            )
        )
    }

    // MARK: - Content formatting

    private var authorDisplayName: String {
        message.sender
    }

    private var shortTime: String {
        Self.timeFormatter.string(from: message.timestamp)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Lightweight rich formatting: tappable links and bold @mentions.
    /// Mono is reserved for technical bits elsewhere; chat text is humanist sans.
    private var formattedContent: AttributedString {
        let content = message.content
        var result = AttributedString(content)
        result.foregroundColor = bubbleTextColor

        // Linkify URLs (keep the bubble's foreground color for contrast on fills)
        if content.contains("://") || content.lowercased().contains("www.") {
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let nsContent = content as NSString
                let matches = detector.matches(in: content, options: [], range: NSRange(location: 0, length: nsContent.length))
                for match in matches {
                    guard let range = Range(match.range, in: content),
                          let attrRange = Range(range, in: result),
                          let url = match.url else { continue }
                    result[attrRange].link = url
                    result[attrRange].underlineStyle = .single
                    result[attrRange].foregroundColor = isSelf ? bubbleTextColor : SonarTheme.accentDeep
                }
            }
        }

        // Bold @mentions; highlight when we are mentioned
        if content.contains("@") {
            let nsContent = content as NSString
            let matches = MessageFormattingEngine.Patterns.mention.matches(
                in: content, options: [], range: NSRange(location: 0, length: nsContent.length)
            )
            for match in matches {
                guard let range = Range(match.range, in: content),
                      let attrRange = Range(range, in: result) else { continue }
                result[attrRange].font = SonarTheme.uiFont(size: 16, weight: .semibold)
            }
        }

        return result
    }
}
