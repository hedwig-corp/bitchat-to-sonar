//
// SonarPushProcessor.swift
// bitchat
//
// Processes incoming silent push notifications from both servers:
//   - Transponder (Marmot): syncs relay, classifies messages, fires local notifs
//   - Breez NDS: wakes the wallet SDK to complete BOLT12 receives (silent)
//
// This runs from the AppDelegate's didReceiveRemoteNotification handler
// inside the 30-second background execution window iOS provides. A future
// Notification Service Extension (issue #65) will add richer handling.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import UIKit
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

        guard let marmot else {
            log.warning("Marmot not available, showing fallback notification")
            showFallbackNotification()
            completionHandler(.newData)
            return
        }

        Task {
            do {
                let notifications: [DrainNotificationInfo] = try await withTimeout(seconds: TransportConfig.marmotPushSyncTimeoutSeconds) {
                    await marmot.refresh()
                }
                if notifications.isEmpty {
                    log.info("Marmot sync completed from push, no new messages")
                } else {
                    log.info("Marmot sync completed from push, \(notifications.count) new message(s)")
                    let prefs = SonarLocalNotificationPrefs(
                        enabled: true,
                        showNames: UserDefaults.standard.object(forKey: "sonar.notifications.showNames") as? Bool ?? false,
                        showPreview: UserDefaults.standard.object(forKey: "sonar.notifications.showPreview") as? Bool ?? false
                    )
                    for notif in notifications {
                        let senderName = await marmot.resolveSenderName(npub: notif.senderNpub)
                        let conversationTitle = notif.groupName.isEmpty ? senderName : "\(senderName) in \(notif.groupName)"
                        guard let routed = SonarLocalNotificationRouter.make(
                            idKey: UUID().uuidString,
                            kind: .message,
                            conversationTitle: conversationTitle,
                            preview: notif.contentPreview.isEmpty ? nil : notif.contentPreview,
                            prefs: prefs
                        ) else { continue }
                        NotificationService.shared.sendLocalNotification(
                            title: routed.title,
                            body: routed.body,
                            identifier: routed.identifier
                        )
                    }
                }
                completionHandler(.newData)
            } catch {
                log.warning("Marmot sync from push failed: \(error)")
                showFallbackNotification()
                completionHandler(.failed)
            }
        }
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

    private static func showFallbackNotification() {
        NotificationService.shared.sendLocalNotification(
            title: "New Sonar message",
            body: "Open Sonar to read it.",
            identifier: "marmot-push-\(UUID().uuidString)"
        )
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
