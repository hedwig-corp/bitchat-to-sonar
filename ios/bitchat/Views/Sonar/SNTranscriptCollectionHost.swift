//
// SNTranscriptCollectionHost.swift
// bitchat
//
// Phase 3 UIKit transcript engine (Signal ConversationViewController shape):
// full-height UICollectionView + keyboardLayoutGuide composer + owned
// contentInset; open / pin / lockstep / continuity via SNTranscriptScrollPolicy.
// Cells are PRE-MEASURED (SNTranscriptRowHeightCache + sizeForItemAt) so
// contentSize is exact from the first layout — no self-sizing settle, no
// under-measured opens. Day markers are pinned section headers.
// Top-aligned short feeds only (no Spike B reverse).
// See docs/brainstorms/2026-07-18-signal-transcript-long-term-plan.md.
//

import SwiftUI
import TranscriptEngine
#if os(iOS)
import UIKit
#endif

// MARK: - Flag

/// Feature flag for the UICollectionView transcript host. Phase 3 cutover:
/// default ON in every build. Kill switches: env `=0`, or (Debug only) the
/// Settings → Developer toggle (UserDefaults).
enum SNTranscriptCollectionHostFlag {
    static let environmentKey = "SONAR_TRANSCRIPT_COLLECTION_HOST"
    static let defaultsKey = "sonar.transcript.collectionHost"

    /// Default ON (Debug + Release). Env `=0` forces the SNMsgList fallback,
    /// env `=1` forces the host. UserDefaults is honored only in DEBUG so a
    /// dogfood toggle cannot stick a Release/TestFlight install on the
    /// fallback with no UI to recover.
    static var isEnabled: Bool {
        switch ProcessInfo.processInfo.environment[environmentKey] {
        case "0": return false
        case "1": return true
        default: break
        }
        #if DEBUG
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool {
            return stored
        }
        #endif
        return true
    }

    static var entryVisible: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Settings → Developer toggle (Debug builds). Env still overrides.
    static func setEnabled(_ enabled: Bool) {
        #if DEBUG
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        #endif
    }
}

/// Fingerprint media geometry for the row-height cache key. Nil dims and
/// later MIP-04 bounds must not share a cache entry (reserved box changes).
func snCollectionHostMediaHeightFingerprint(_ media: [SNMediaItem]) -> String {
    media.map { "\($0.width ?? 0)x\($0.height ?? 0):\($0.mime)" }.joined(separator: ",")
}

// MARK: - SwiftUI entry (DM / Mac)

/// Replaces the production `SNMsgList` + sibling `SNComposer` pair when the
/// collection-host flag is on. iOS uses a UIKit collection host; macOS uses a
/// SwiftUI full-height + overlay-composer ownership model with the same policy.
struct SNTranscriptCollectionHost<Composer: View>: View {
    let msgs: [SNMessage]
    let showAuthors: Bool
    var peerName: String = ""
    var money: (Int64) -> String = { sonarFormatSats($0) }
    var fiatText: (Int64) -> String? = { _ in nil }
    var onTapAuthor: ((SNMessage) -> Void)? = nil
    var mediaPipeline: SNMediaPipeline = .unavailable
    var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)? = nil
    var onTapPack: ((String) -> Void)? = nil
    var onRetry: ((SNMessage) -> Void)? = nil
    var loadOlder: (() async -> Bool)? = nil
    var loadNewest: (() async -> Void)? = nil
    var unreadCountAtOpen: UInt64? = nil
    var expectedNewestDate: Date? = nil
    @ViewBuilder var composer: () -> Composer

    var body: some View {
        #if os(iOS)
        // UIKit owns IME via keyboardLayoutGuide. If SwiftUI also keyboard-avoids
        // this representable, the composer floats ~one keyboard height above the
        // IME (snCollectionHostFloatingComposerGap). Kill-switch SNMsgList keeps
        // the sibling-composer path and still wants SwiftUI avoidance.
        SNTranscriptCollectionRepresentable(
            msgs: msgs,
            showAuthors: showAuthors,
            peerName: peerName,
            money: money,
            fiatText: fiatText,
            onTapAuthor: onTapAuthor,
            mediaPipeline: mediaPipeline,
            loadSticker: loadSticker,
            onTapPack: onTapPack,
            onRetry: onRetry,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            composer: composer
        )
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #else
        SNTranscriptCollectionSwiftUIHost(
            msgs: msgs,
            showAuthors: showAuthors,
            peerName: peerName,
            money: money,
            fiatText: fiatText,
            onTapAuthor: onTapAuthor,
            mediaPipeline: mediaPipeline,
            loadSticker: loadSticker,
            onTapPack: onTapPack,
            onRetry: onRetry,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            composer: composer
        )
        #endif
    }
}

// MARK: - macOS / shared SwiftUI ownership host

/// Full-height scroll + overlay composer; bottom content pad = measured chrome.
/// Short feeds stay top-aligned. The Mac list engine stays SNMsgList (AppKit
/// collection parity is a tracked gap — docs/SIGNAL-TRANSCRIPT-PATTERNS.md).
private struct SNTranscriptCollectionSwiftUIHost<Composer: View>: View {
    let msgs: [SNMessage]
    let showAuthors: Bool
    var peerName: String
    var money: (Int64) -> String
    var fiatText: (Int64) -> String?
    var onTapAuthor: ((SNMessage) -> Void)?
    var mediaPipeline: SNMediaPipeline
    var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    var onTapPack: ((String) -> Void)?
    var onRetry: ((SNMessage) -> Void)?
    var loadOlder: (() async -> Bool)?
    var loadNewest: (() async -> Void)?
    var unreadCountAtOpen: UInt64?
    var expectedNewestDate: Date?
    @ViewBuilder var composer: () -> Composer

    @State private var chromeHeight: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottom) {
            SNMsgList(
                msgs: msgs,
                showAuthors: showAuthors,
                peerName: peerName,
                money: money,
                fiatText: fiatText,
                onTapAuthor: onTapAuthor,
                mediaPipeline: mediaPipeline,
                loadSticker: loadSticker,
                onTapPack: onTapPack,
                onRetry: onRetry,
                loadOlder: loadOlder,
                loadNewest: loadNewest,
                unreadCountAtOpen: unreadCountAtOpen,
                expectedNewestDate: expectedNewestDate
            )
            .padding(.bottom, chromeHeight)

            composer()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SNCollectionHostChromeHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .onPreferenceChange(SNCollectionHostChromeHeightKey.self) { chromeHeight = $0 }
    }
}

private struct SNCollectionHostChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 56
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Floating day pill for pinned section headers (Signal's sticky date header).
struct SNStickyDayHeader: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
            .foregroundColor(SonarTheme.text2)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(SonarTheme.surface2.opacity(0.94)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}


#if os(iOS)

/// Cell bubble bridge. Render flags (`cont` / `showAuthor` / `showState`) are
/// computed by the controller so the measure pass and the cell agree; the
/// expanded set lives on the controller so "read more" survives cell reuse and
/// re-measures the row.
struct SNCollectionHostMessageRow: View {
    let message: SNMessage
    let cont: Bool
    let showAuthor: Bool
    let showState: Bool
    let peerName: String
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onTapAuthor: ((SNMessage) -> Void)?
    let mediaPipeline: SNMediaPipeline
    let loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    let onTapPack: ((String) -> Void)?
    let onRetry: ((SNMessage) -> Void)?
    /// Collection column width (margins already subtracted). Never UIScreen —
    /// measure and cell must agree under Split View.
    let columnWidth: CGFloat
    let expandedMessageIDs: Set<String>
    let onExpandedChange: (Set<String>) -> Void

    var body: some View {
        let m = message
        let textMax = columnWidth * 0.78
        let mediaMax = columnWidth * 0.72
        Group {
            if let call = m.call {
                SNCallLogRow(call: call, mine: m.mine, time: m.time)
            } else if m.pay != nil {
                SNPayBubble(
                    m: m,
                    peerName: peerName,
                    money: money,
                    fiatText: fiatText,
                    maxBubbleWidth: textMax
                )
            } else if !m.media.isEmpty {
                SNMediaBubble(
                    m: m,
                    maxBubbleWidth: mediaMax,
                    showState: showState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    pipeline: mediaPipeline
                )
            } else if m.stickerRef != nil {
                SNStickerBubble(
                    m: m,
                    showAuthor: showAuthor,
                    showState: showState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    load: loadSticker,
                    onTapPack: onTapPack
                )
            } else if m.action {
                Text(verbatim: m.text)
                    .font(SonarTheme.uiFont(size: 13).italic())
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .padding(.horizontal, 20)
            } else {
                SNMsgBubble(
                    m: m,
                    preview: SonarTranscriptDisplayPolicy.preview(m.text),
                    expandedMessageIDs: Binding(
                        get: { expandedMessageIDs },
                        set: { onExpandedChange($0) }
                    ),
                    showAuthor: showAuthor,
                    cont: cont,
                    showState: showState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    maxBubbleWidth: textMax,
                    onTapAuthor: onTapAuthor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

#endif
