//
// ShowMoreButton.swift
// bitchat
//
// The one expand/collapse control for truncated message bubbles.
//
// Exists because the 44pt hit target was previously hand-maintained on three
// separate bubble surfaces (SNMsgBubble, SonarMessageBubbleView,
// TextMessageView) and drifted: two of them chained the sizing modifiers onto
// the Button wrapper instead of the label, which widens the layout box while
// leaving the blank part of the tap area dead (#357 / PR #358). Keeping the
// shape here makes that invariant structural — a fourth surface cannot get it
// wrong without editing this file.
//
// Compose mirror: MessageBubble in App.kt, where heightIn(min = 44.dp) sits
// outside clickable() so the constraint propagates into the clickable node.
//

import SwiftUI

struct ShowMoreButton: View {

    /// Apple HIG minimum tap target, applied to BOTH axes. Height alone is not
    /// enough: short localized labels (zh-Hans 展开 / 收起 is two glyphs) would
    /// otherwise leave a target under 44pt wide. The entire area must hit-test,
    /// not just the glyphs — see the note on `label` below.
    static let minimumHitTarget: CGFloat = 44

    let isExpanded: Bool
    let font: Font
    let color: Color
    /// Horizontal inset applied *inside* the label, so it grows the tap area
    /// rather than padding a smaller one.
    var horizontalPadding: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // INVARIANT: `.buttonStyle(.plain)` hit-tests the label subtree, so
            // `frame` and `contentShape` MUST stay inside this closure. Moved
            // onto the Button — which the `Button(<title>) { }` convenience
            // initializer quietly invites — they widen the layout box and the
            // padding around the text stops responding to taps.
            Text(isExpanded
                 ? String(localized: "content.message.show_less")
                 : String(localized: "content.message.show_more"))
                .font(font)
                .foregroundColor(color)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: Self.minimumHitTarget, minHeight: Self.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The label alone tells VoiceOver the action ("show more") but not the
        // current state. Mirrors the Compose `stateDescription`.
        .accessibilityValue(isExpanded
                            ? String(localized: "content.message.expanded")
                            : String(localized: "content.message.collapsed"))
    }
}

extension ShowMoreButton {
    /// The Sonar bubble styling, in one place: `SNMsgBubble` and
    /// `SonarMessageBubbleView` must not drift apart the way the hit-target
    /// modifiers did (#357).
    static func sonar(
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> ShowMoreButton {
        ShowMoreButton(
            isExpanded: isExpanded,
            font: SonarTheme.uiFont(size: 12, weight: .semibold),
            color: SonarTheme.accentDeep,
            horizontalPadding: 6,
            action: action
        )
    }
}
