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
// replaces that with prefs-aware copy whenever local unread state is ready
// (Android SonarPushProcessingService parity).
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
            var synced = false
            do {
                _ = try await withTimeout(seconds: TransportConfig.marmotPushSyncTimeoutSeconds) {
                    await marmot.refresh()
                }
                synced = true
            } catch {
                log.warning("Marmot sync from push failed or timed out: \(error)")
                // Partial drain often already wrote the pushed row; load local
                // summaries so we can still render titled notifications.
                await marmot.loadLocalSummaries()
            }

            guard prefs.enabled else {
                log.info("Marmot wakeup done (synced=\(synced)), notifications disabled")
                completionHandler(synced ? .newData : .failed)
                return
            }

            let notified = await notifyUnreadConversations(marmot: marmot, prefs: prefs)
            switch (notified > 0, synced) {
            case (true, _):
                log.info("Marmot wakeup: notified for \(notified) conversation(s) (synced=\(synced))")
                removeDeliveredGenericMessageBanners()
                completionHandler(.newData)
            case (false, true):
                log.info("Marmot sync completed from push, no unread messages")
                completionHandler(.newData)
            case (false, false):
                log.warning("Marmot sync timed out with nothing unread, showing fallback")
                showFallbackNotification(prefs: prefs)
                completionHandler(.failed)
            }
        }
    }

    /// Render titled notifications for every unread conversation from local
    /// storage. Returns how many conversations were notified.
    @MainActor
    private static func notifyUnreadConversations(
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> Int {
        let unread = marmot.conversationSummariesByGroup.values.filter { $0.unreadCount > 0 }
        if unread.isEmpty { return 0 }

        var notified = 0
        for summary in unread {
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
                // Only label as a group when the conversation name is distinct
                // from the sender (direct chats often reuse the peer name).
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

    /// Drop the NSE's plaintext-free placeholder once we have real local copy,
    /// so the lock screen shows the prefs-aware title/body instead of both.
    private static func removeDeliveredGenericMessageBanners() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes.compactMap { note -> String? in
                let content = note.request.content
                guard content.title == "New Sonar message",
                      content.body == "Open Sonar to read it."
                else { return nil }
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
