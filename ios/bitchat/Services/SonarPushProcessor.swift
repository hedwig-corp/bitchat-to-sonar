//
// SonarPushProcessor.swift
// bitchat
//
// Processes incoming silent push notifications from both servers:
//   - Transponder (Marmot): syncs relay, classifies messages, fires local notifs
//   - Breez NDS: wakes the wallet SDK to complete BOLT12 receives (silent)
//
// This runs from the AppDelegate's didReceiveRemoteNotification handler
// inside the 30-second background execution window iOS provides. The NSE
// may already have posted a generic banner for killed-app wakes; this path
// replaces that with prefs-aware copy whenever newly drained (or newly
// changed unread) local state is ready.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import UIKit
import UserNotifications
import os
import SonarCore

private struct SonarPushTimeoutError: Error {}

enum SonarPushProcessor {

    /// userInfo key set by the NSE on Transponder placeholders. Cleanup must
    /// match this identity — never title/body (those strings are also the
    /// router's privacy fallback when Show names + Message preview are off).
    static let nsePlaceholderUserInfoKey = "sonar.nsePlaceholder"

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.hedwig.sonar",
        category: "SonarPushProcessor"
    )

    /// Single-flight Marmot wake. Concurrent Transponder pushes coalesce onto
    /// one owner task; `marmotWakeNeedsRerun` forces another refresh after any
    /// push observed while the owner is still finishing (name resolve / notify).
    @MainActor
    private static var marmotWakeInFlight: Task<UIBackgroundFetchResult, Never>?
    @MainActor
    private static var marmotWakeNeedsRerun = false

    /// Classify and process a remote notification payload.
    /// Returns true if the push was handled, false otherwise.
    @MainActor
    static func process(
        userInfo: [AnyHashable: Any],
        marmot: MarmotChatModel?,
        wallet: SonarWalletProviding?,
        fetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let source = userInfo["source"] as? String ?? ""

        if source == "breez" || userInfo["notification_type"] != nil {
            processBreezWakeup(wallet: wallet, completionHandler: fetchCompletionHandler)
        } else {
            processMarmotWakeup(marmot: marmot, completionHandler: fetchCompletionHandler)
        }
    }

    // MARK: - Marmot (transponder)

    @MainActor
    private static func processMarmotWakeup(
        marmot: MarmotChatModel?,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        log.info("Processing Marmot push wakeup")
        let prefs = SonarNotificationPreferenceStore.loadMerged()

        guard let marmot else {
            if prefs.enabled {
                log.warning("Marmot not available, showing fallback notification")
            } else {
                log.info("Marmot not available, notifications disabled")
            }
            showFallbackNotification(prefs: prefs)
            completionHandler(.newData)
            return
        }

        if let existing = marmotWakeInFlight {
            // Coalesce duplicate work, but ensure at least one refresh runs
            // after this push — the in-flight wake may already be past drain
            // (e.g. resolving sender names) and would otherwise miss the row.
            log.info("Marmot push wake already in flight — coalescing with trailing refresh")
            marmotWakeNeedsRerun = true
            Task {
                let result = await existing.value
                completionHandler(result)
            }
            return
        }

        let task = Task { @MainActor () -> UIBackgroundFetchResult in
            defer {
                marmotWakeInFlight = nil
                marmotWakeNeedsRerun = false
            }
            // Own banners before any suspension so the live sink cannot emit
            // during the NSE snapshot await (or later wake work).
            // One ownership span for the whole single-flight + trailing refresh
            // loop — per-iteration begin/end cleared notified IDs and double-bannered.
            marmot.beginPushWakeNotificationOwnership()
            defer { marmot.endPushWakeNotificationOwnership() }

            // Snapshot placeholders present at wake start. Only those may be
            // removed when this wake posts titled copy — NSEs delivered for
            // other chats during the wake must stay until their own wake runs.
            let nsePlaceholderSnapshot = await deliveredNSEPlaceholderIds()

            var overall: UIBackgroundFetchResult = .noData
            var clearNSEPlaceholders = false
            repeat {
                marmotWakeNeedsRerun = false
                let outcome = await runMarmotWakeup(marmot: marmot, prefs: prefs)
                overall = mergeFetchResult(overall, outcome.fetchResult)
                clearNSEPlaceholders = clearNSEPlaceholders || outcome.shouldClearNSEPlaceholders
            } while marmotWakeNeedsRerun

            if clearNSEPlaceholders {
                removeDeliveredNSEPlaceholderBanners(onlyIdentifiers: nsePlaceholderSnapshot)
            }
            return overall
        }
        marmotWakeInFlight = task
        Task { @MainActor in
            let result = await task.value
            completionHandler(result)
        }
    }

    private struct MarmotWakeOutcome {
        let fetchResult: UIBackgroundFetchResult
        let shouldClearNSEPlaceholders: Bool
    }

    @MainActor
    private static func runMarmotWakeup(
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> MarmotWakeOutcome {
        // Ownership is held by the outer single-flight loop so trailing
        // refreshes share one notified-ID set.

        // Hydrate the unread baseline from local storage BEFORE refresh.
        // Cold/background launches often have an empty in-memory summary
        // cache; capturing that empty map would treat every existing unread
        // chat as "new" after refresh and re-alert stale threads.
        // Only trust the baseline when the local read actually succeeded —
        // a failed load leaves the cache empty and must not count as hydrated.
        _ = await marmot.ensureConnected()
        let baselineHydrated = await marmot.loadLocalSummaries()
        let beforeUnread = unreadFingerprint(marmot: marmot)

        var drained: [DrainNotificationInfo] = []
        var synced = false
        do {
            drained = try await withTimeout(seconds: TransportConfig.marmotPushSyncTimeoutSeconds) {
                await marmot.refresh()
            }
            synced = true
        } catch {
            log.warning("Marmot sync from push failed or timed out: \(error)")
            // Partial drain often already wrote the pushed row; reload local
            // summaries so a delta check can still render titled copy.
            _ = await marmot.loadLocalSummaries()
        }

        guard prefs.enabled else {
            log.info("Marmot wakeup done (synced=\(synced)), notifications disabled")
            return MarmotWakeOutcome(
                fetchResult: synced ? .newData : .failed,
                shouldClearNSEPlaceholders: false
            )
        }

        // Prefer drain metadata, then also run unread-delta so rows that land
        // via gap recovery after the returned drain list are not dropped.
        // Delta skips message tips already bannered from the drain list.
        var notified = 0
        if !drained.isEmpty {
            notified = await notifyDrained(drained, marmot: marmot, prefs: prefs)
        }
        // Reload summaries so delta sees gap-recovery advances during name resolve.
        _ = await marmot.loadLocalSummaries()
        notified += await notifyNewlyUnread(
            before: beforeUnread,
            baselineHydrated: baselineHydrated,
            marmot: marmot,
            prefs: prefs
        )

        switch (notified > 0, synced) {
        case (true, _):
            log.info("Marmot wakeup: notified for \(notified) conversation(s) (synced=\(synced))")
            // Wipe of NSE placeholders is deferred to the outer loop with a
            // start-of-wake snapshot so overlapping chats are not erased.
            return MarmotWakeOutcome(fetchResult: .newData, shouldClearNSEPlaceholders: true)
        case (false, true):
            log.info("Marmot sync completed from push, no new unread messages")
            return MarmotWakeOutcome(fetchResult: .newData, shouldClearNSEPlaceholders: false)
        case (false, false):
            log.warning("Marmot sync timed out with nothing new unread, showing fallback")
            showFallbackNotification(prefs: prefs)
            // Avoid stacking NSE generic + local fallback generics (snapshot-scoped).
            return MarmotWakeOutcome(fetchResult: .failed, shouldClearNSEPlaceholders: true)
        }
    }

    /// Fingerprint unread conversations so a wake can detect *new* activity
    /// without re-alerting every leftover unread thread.
    @MainActor
    private static func unreadFingerprint(
        marmot: MarmotChatModel
    ) -> [String: SonarPushUnreadDelta.Fingerprint] {
        var out: [String: SonarPushUnreadDelta.Fingerprint] = [:]
        for summary in marmot.conversationSummariesByGroup.values where summary.unreadCount > 0 {
            out[summary.groupIdHex] = SonarPushUnreadDelta.Fingerprint(
                unread: summary.unreadCount,
                latestAt: summary.latestAt,
                content: summary.latestContent
            )
        }
        return out
    }

    @MainActor
    private static func notifyDrained(
        _ drained: [DrainNotificationInfo],
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> Int {
        var notified = 0
        for notif in drained {
            let kind: SonarLocalNotificationKind = {
                switch sonarNotificationClassifyContent(content: notif.contentPreview) {
                case .call: return .call
                case .payment: return .payment
                case .trill: return .trill
                default: return .message
                }
            }()
            if kind == .call { continue }
            // Per-chat mute. The drain payload carries no group id, so a
            // muted DM is matched by sender npub; muted GROUPS are only
            // caught by the summary path below (documented gap).
            if notif.groupName.isEmpty, !notif.senderNpub.isEmpty,
               SonarChatMuteStore.shared.isMuted(notif.senderNpub) {
                continue
            }
            // Receiver trill throttle: one audible alert per chat per window;
            // excess trills still banner, silently.
            var sound: SonarNotificationSound = .standard
            if kind == .trill {
                let throttleKey = notif.groupName.isEmpty ? notif.senderNpub : notif.groupName
                sound = SonarTrillThrottle.shared.admit(chatKey: throttleKey) ? .trill : .silent
            }

            let senderName: String?
            if prefs.showNames, !notif.senderNpub.isEmpty {
                senderName = await marmot.resolveSenderName(npub: notif.senderNpub)
            } else {
                senderName = nil
            }
            let groupName = notif.groupName.isEmpty ? nil : notif.groupName
            let conversationTitle = groupName ?? senderName
            // R-004: prefer message id; fall back to content-stable key only when
            // core omitted id (should not happen for real drains).
            let idKey = notif.messageIdHex.isEmpty
                ? [
                    notif.senderNpub,
                    notif.groupName,
                    notif.contentPreview,
                ].joined(separator: "|")
                : notif.messageIdHex
            let conversationId = notif.groupIdHex.isEmpty
                ? nil
                : "marmot:" + notif.groupIdHex
            var userInfo: [String: Any] = [:]
            if let conversationId {
                userInfo[SonarNotificationKeys.conversationId] = conversationId
            }
            if !notif.messageIdHex.isEmpty {
                userInfo["sonar.messageId"] = notif.messageIdHex
            }

            guard let routed = SonarLocalNotificationRouter.make(
                idKey: idKey.isEmpty ? UUID().uuidString : idKey,
                kind: kind,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: notif.contentPreview.isEmpty ? nil : notif.contentPreview,
                prefs: prefs,
                userInfo: userInfo
            ) else { continue }

            NotificationService.shared.sendLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier,
                userInfo: routed.userInfo,
                sound: sound
            )
            // Correlate to local message IDs (handles truncated drain previews).
            marmot.notePushWakeNotified(drain: notif)
            notified += 1
        }
        return notified
    }

    /// Notify only unread conversations that advanced during this wake.
    @MainActor
    private static func notifyNewlyUnread(
        before: [String: SonarPushUnreadDelta.Fingerprint],
        baselineHydrated: Bool,
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> Int {
        let after = marmot.conversationSummariesByGroup.values.filter { summary in
            SonarPushUnreadDelta.isNewlyAdvanced(
                groupId: summary.groupIdHex,
                after: SonarPushUnreadDelta.Fingerprint(
                    unread: summary.unreadCount,
                    latestAt: summary.latestAt,
                    content: summary.latestContent
                ),
                before: before,
                baselineHydrated: baselineHydrated
            )
        }
        if after.isEmpty { return 0 }

        var notified = 0
        for summary in after {
            // Skip only when drain already bannered *this* tip message.
            // Group-level exclude dropped a second in-group advance that landed
            // via gap recovery after the drain list was returned.
            if marmot.pushWakeAlreadyNotifiedLatest(
                groupIdHex: summary.groupIdHex,
                content: summary.latestContent
            ) {
                continue
            }

            let kind: SonarLocalNotificationKind = {
                switch sonarNotificationClassifyContent(content: summary.latestContent) {
                case .call: return .call
                case .payment: return .payment
                case .trill: return .trill
                default: return .message
                }
            }()
            if kind == .call { continue }
            // Per-chat mute: unread still accrues, no banner.
            if SonarChatMuteStore.shared.isMuted(summary.groupIdHex) { continue }
            // Receiver trill throttle (silent banner inside the window).
            var sound: SonarNotificationSound = .standard
            if kind == .trill {
                sound = SonarTrillThrottle.shared.admit(chatKey: summary.groupIdHex) ? .trill : .silent
            }

            let senderName: String?
            if prefs.showNames, !summary.latestSenderNpub.isEmpty {
                senderName = await marmot.resolveSenderName(npub: summary.latestSenderNpub)
            } else {
                senderName = nil
            }
            let conversationTitle = summary.name.isEmpty ? senderName : summary.name
            let groupName: String? = {
                guard let senderName, !summary.name.isEmpty, summary.name != senderName else {
                    return nil
                }
                return summary.name
            }()

            let conversationId = summary.groupIdHex.isEmpty
                ? nil
                : "marmot:" + summary.groupIdHex
            let userInfo: [String: Any] = conversationId.map {
                [SonarNotificationKeys.conversationId: $0]
            } ?? [:]

            guard let routed = SonarLocalNotificationRouter.make(
                idKey: summary.groupIdHex,
                kind: kind,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: summary.latestContent.isEmpty ? nil : summary.latestContent,
                prefs: prefs,
                unreadCount: summary.unreadCount,
                userInfo: userInfo
            ) else { continue }

            NotificationService.shared.sendLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier,
                userInfo: routed.userInfo,
                sound: sound
            )
            marmot.notePushWakeNotified(groupIdHex: summary.groupIdHex, content: summary.latestContent)
            notified += 1
        }
        return notified
    }

    // MARK: - Breez (NDS)

    @MainActor
    private static func processBreezWakeup(
        wallet: SonarWalletProviding?,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        log.info("Processing Breez push wakeup (silent)")

        guard let wallet else {
            log.info("Wallet not available for Breez wakeup")
            completionHandler(.noData)
            return
        }

        guard case .ready = wallet.state else {
            log.info("Wallet not ready for Breez wakeup")
            completionHandler(.noData)
            return
        }

        log.info("Breez wakeup: wallet already running, SDK will process event")
        completionHandler(.newData)
    }

    // MARK: - Helpers

    private static func mergeFetchResult(
        _ a: UIBackgroundFetchResult,
        _ b: UIBackgroundFetchResult
    ) -> UIBackgroundFetchResult {
        // Prefer evidence of work: newData > failed > noData.
        switch (a, b) {
        case (.newData, _), (_, .newData): return .newData
        case (.failed, _), (_, .failed): return .failed
        default: return .noData
        }
    }

    private static func showFallbackNotification(prefs: SonarLocalNotificationPrefs) {
        var mutedPreview = prefs
        mutedPreview.showPreview = false
        guard let routed = SonarLocalNotificationRouter.make(
            idKey: UUID().uuidString,
            kind: .message,
            conversationTitle: nil,
            preview: nil,
            prefs: mutedPreview
        ) else { return }
        NotificationService.shared.sendLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: routed.identifier
        )
    }

    /// Drop NSE Transponder placeholders once we have real local copy.
    /// Matches `sonar.nsePlaceholder` only — never user-visible title/body.
    static func isNSEPlaceholder(_ content: UNNotificationContent) -> Bool {
        if let flag = content.userInfo[nsePlaceholderUserInfoKey] as? Bool { return flag }
        if let flag = content.userInfo[nsePlaceholderUserInfoKey] as? NSNumber {
            return flag.boolValue
        }
        return false
    }

    /// Pure filter used by wipe + tests: keep only placeholder ids that were
    /// already delivered when this wake started (`allowed`).
    static func nsePlaceholderIdsToRemove(
        deliveredPlaceholderIds: Set<String>,
        allowedFromWakeStart: Set<String>
    ) -> [String] {
        deliveredPlaceholderIds.intersection(allowedFromWakeStart).sorted()
    }

    private static func deliveredNSEPlaceholderIds() async -> Set<String> {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                let ids = Set(notes.compactMap { note -> String? in
                    guard isNSEPlaceholder(note.request.content) else { return nil }
                    return note.request.identifier
                })
                continuation.resume(returning: ids)
            }
        }
    }

    private static func removeDeliveredNSEPlaceholderBanners(onlyIdentifiers: Set<String>) {
        // Empty snapshot ⇒ nothing was present at wake start; do not wipe
        // placeholders that arrived for other chats during this wake.
        guard !onlyIdentifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let delivered = Set(notes.compactMap { note -> String? in
                guard isNSEPlaceholder(note.request.content) else { return nil }
                return note.request.identifier
            })
            let ids = nsePlaceholderIdsToRemove(
                deliveredPlaceholderIds: delivered,
                allowedFromWakeStart: onlyIdentifiers
            )
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SonarPushTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

#endif
