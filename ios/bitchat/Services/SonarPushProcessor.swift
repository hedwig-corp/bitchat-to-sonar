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

        Task {
            // Own push-wake banners so SonarAppStore's live message sink does
            // not also fire for the same drained rows (duplicate lock-screen
            // banners with different identifiers).
            marmot.beginPushWakeNotificationOwnership()
            defer { marmot.endPushWakeNotificationOwnership() }

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
                // Partial drain often already wrote the pushed row; load local
                // summaries so a delta check can still render titled copy.
                await marmot.loadLocalSummaries()
            }

            guard prefs.enabled else {
                log.info("Marmot wakeup done (synced=\(synced)), notifications disabled")
                completionHandler(synced ? .newData : .failed)
                return
            }

            let notified: Int
            if !drained.isEmpty {
                notified = await notifyDrained(drained, marmot: marmot, prefs: prefs)
            } else {
                // Never fan out to every stale unread chat — only conversations
                // whose unread fingerprint advanced during this wake.
                notified = await notifyNewlyUnread(
                    before: beforeUnread,
                    marmot: marmot,
                    prefs: prefs
                )
            }

            switch (notified > 0, synced) {
            case (true, _):
                log.info("Marmot wakeup: notified for \(notified) conversation(s) (synced=\(synced))")
                removeDeliveredNSEPlaceholderBanners()
                completionHandler(.newData)
            case (false, true):
                log.info("Marmot sync completed from push, no new unread messages")
                completionHandler(.newData)
            case (false, false):
                log.warning("Marmot sync timed out with nothing new unread, showing fallback")
                showFallbackNotification(prefs: prefs)
                completionHandler(.failed)
            }
        }
    }

    /// Fingerprint unread conversations so a wake can detect *new* activity
    /// without re-alerting every leftover unread thread.
    @MainActor
    private static func unreadFingerprint(
        marmot: MarmotChatModel
    ) -> [String: (unread: UInt64, latestAt: Date, content: String)] {
        var out: [String: (unread: UInt64, latestAt: Date, content: String)] = [:]
        for summary in marmot.conversationSummariesByGroup.values where summary.unreadCount > 0 {
            out[summary.groupIdHex] = (
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
                default: return .message
                }
            }()
            if kind == .call { continue }

            let senderName: String?
            if prefs.showNames, !notif.senderNpub.isEmpty {
                senderName = await marmot.resolveSenderName(npub: notif.senderNpub)
            } else {
                senderName = nil
            }
            let groupName = notif.groupName.isEmpty ? nil : notif.groupName
            let conversationTitle = groupName ?? senderName
            // Stable-ish id so a retrying wake replaces rather than stacking.
            let idKey = [
                notif.senderNpub,
                notif.groupName,
                notif.contentPreview,
            ].joined(separator: "|")

            guard let routed = SonarLocalNotificationRouter.make(
                idKey: idKey,
                kind: kind,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: notif.contentPreview.isEmpty ? nil : notif.contentPreview,
                prefs: prefs
            ) else { continue }

            NotificationService.shared.sendLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier
            )
            notified += 1
        }
        return notified
    }

    /// Notify only unread conversations that advanced during this wake.
    @MainActor
    private static func notifyNewlyUnread(
        before: [String: (unread: UInt64, latestAt: Date, content: String)],
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> Int {
        let after = marmot.conversationSummariesByGroup.values.filter { summary in
            guard summary.unreadCount > 0 else { return false }
            guard let prior = before[summary.groupIdHex] else { return true }
            return summary.unreadCount > prior.unread
                || summary.latestAt > prior.latestAt
                || summary.latestContent != prior.content
        }
        if after.isEmpty { return 0 }

        var notified = 0
        for summary in after {
            let kind: SonarLocalNotificationKind = {
                switch sonarNotificationClassifyContent(content: summary.latestContent) {
                case .call: return .call
                case .payment: return .payment
                default: return .message
                }
            }()
            if kind == .call { continue }

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

            guard let routed = SonarLocalNotificationRouter.make(
                idKey: summary.groupIdHex,
                kind: kind,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: summary.latestContent.isEmpty ? nil : summary.latestContent,
                prefs: prefs,
                unreadCount: summary.unreadCount
            ) else { continue }

            NotificationService.shared.sendLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier
            )
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

    private static func removeDeliveredNSEPlaceholderBanners() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes.compactMap { note -> String? in
                guard isNSEPlaceholder(note.request.content) else { return nil }
                return note.request.identifier
            }
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
