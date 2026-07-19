//
// NotificationService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SonarNotificationSound {
    case standard
    case ble
    /// MSN-style nudge (⚡TRILL) — the distinct trill bell.
    case trill
    /// Deliver visually with no sound (throttled trills alert silently).
    case silent
}

/// UserInfo / identifier keys shared by Sonar local notifications and the
/// tap handoff in `NotificationDelegate`.
enum SonarNotificationKeys {
    static let conversationId = "sonarConversationId"
    static let peerID = "peerID"
}

/// Pure helpers for which delivered notifications belong to a conversation.
enum SonarNotificationHandoff {
    static func conversationId(from userInfo: [AnyHashable: Any]) -> String? {
        if let id = userInfo[SonarNotificationKeys.conversationId] as? String,
           !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return id
        }
        if let peerID = userInfo[SonarNotificationKeys.peerID] as? String,
           !peerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return peerID
        }
        return nil
    }

    static func matches(userInfo: [AnyHashable: Any], conversationIds: Set<String>) -> Bool {
        guard let id = conversationId(from: userInfo) else { return false }
        return conversationIds.contains(id)
    }
}

final class NotificationService {
    static let shared = NotificationService()
    private static let standardNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_notification.wav")
    )
    private static let bleNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_ble_notification.wav")
    )
    private static let trillNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_trill.wav")
    )

    /// Returns true if running in test environment (XCTest, Swift Testing, or CI)
    private var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil ||
               env["XCTestConfigurationFilePath"] != nil ||
               env["XCTestBundlePath"] != nil ||
               env["GITHUB_ACTIONS"] != nil ||
               env["CI"] != nil
    }

    private init() {}

    func requestAuthorization() {
        guard !isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                // Permission granted
            } else {
                // Permission denied
            }
        }
    }
    
    func sendLocalNotification(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active,
        sound: SonarNotificationSound = .standard
    ) {
        guard !isRunningTests else { return }
        // Central per-chat mute gate: every conversation-scoped local
        // notification funnels through here, so a muted chat suppresses ALL
        // kinds (message/payment/trill/BLE) without sprinkling checks at
        // call sites. Rows and unread badges still accrue upstream.
        if let userInfo,
           let conversationId = SonarNotificationHandoff.conversationId(from: userInfo),
           SonarChatMuteStore.shared.isMuted(conversationId) {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = switch sound {
        case .standard: Self.standardNotificationSound
        case .ble: Self.bleNotificationSound
        case .trill: Self.trillNotificationSound
        case .silent: nil
        }
        content.interruptionLevel = interruptionLevel

        if let userInfo = userInfo {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
    
    func sendMentionNotification(
        from sender: String,
        message: String,
        sound: SonarNotificationSound = .standard
    ) {
        guard let routed = Self.routedMentionNotification(
            sender: sender,
            message: message,
            prefs: SonarNotificationPreferenceStore.loadMerged()
        ) else { return }

        sendLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: routed.identifier,
            sound: sound
        )
    }

    func sendPrivateMessageNotification(
        from sender: String,
        message: String,
        peerID: PeerID,
        sound: SonarNotificationSound = .standard
    ) {
        // Callers pass the real sender + body; never discard them for a
        // hard-coded privacy fallback. The router applies Show names /
        // Message preview (and the master Notifications toggle).
        guard let routed = Self.routedPrivateMessageNotification(
            sender: sender,
            message: message,
            peerID: peerID.id,
            prefs: SonarNotificationPreferenceStore.loadMerged()
        ) else { return }

        // Identifier is `private-sonar-message-<peerID>` (replace-per-peer),
        // not a per-message UUID. Multiple unread mesh DMs from the same peer
        // update one banner — intentional lock-screen coalescing.
        sendLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: routed.identifier,
            userInfo: routed.userInfo,
            sound: sound
        )
    }

    /// Mesh private-message routing seam used by `sendPrivateMessageNotification`.
    /// Tests pin this so a hard-coded privacy fallback cannot land without failing.
    static func routedPrivateMessageNotification(
        sender: String,
        message: String,
        peerID: String,
        prefs: SonarLocalNotificationPrefs
    ) -> SonarLocalNotification? {
        var userInfo: [String: Any] = [
            SonarNotificationKeys.peerID: peerID,
            SonarNotificationKeys.conversationId: peerID,
        ]
        if prefs.showNames {
            userInfo["senderName"] = sender
        }
        guard let routed = SonarLocalNotificationRouter.make(
            idKey: peerID,
            kind: .message,
            conversationTitle: sender,
            senderName: sender,
            preview: message,
            prefs: prefs,
            userInfo: userInfo
        ) else { return nil }
        // Keep the `private-` prefix — NotificationDelegate routes taps by it.
        return SonarLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: "private-\(routed.identifier)",
            userInfo: routed.userInfo
        )
    }

    /// Mesh mention routing seam used by `sendMentionNotification`.
    static func routedMentionNotification(
        sender: String,
        message: String,
        prefs: SonarLocalNotificationPrefs,
        idKey: String = UUID().uuidString
    ) -> SonarLocalNotification? {
        guard let routed = SonarLocalNotificationRouter.make(
            idKey: idKey,
            kind: .mention,
            conversationTitle: sender,
            senderName: sender,
            preview: message,
            prefs: prefs
        ) else { return nil }
        return SonarLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: "mention-\(routed.identifier)",
            userInfo: routed.userInfo
        )
    }
    
    // Geohash public chat notification with deep link to a specific geohash
    func sendGeohashActivityNotification(geohash: String, titlePrefix: String = "#", bodyPreview: String) {
        let title = "\(titlePrefix)\(geohash)"
        let identifier = "geo-activity-\(geohash)-\(Date().timeIntervalSince1970)"
        let deeplink = "bitchat://geohash/\(geohash)"
        let userInfo: [String: Any] = ["deeplink": deeplink]
        sendLocalNotification(title: title, body: bodyPreview, identifier: identifier, userInfo: userInfo)
    }

    func sendNetworkAvailableNotification(peerCount: Int) {
        let title = "👥 people nearby on Sonar!"
        let body = peerCount == 1 ? "1 person around" : "\(peerCount) people around"
        // Fixed identifier so iOS updates the existing notification instead of creating new ones
        let identifier = "network-available"

        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            interruptionLevel: .timeSensitive,
            sound: .ble
        )
    }

    /// Remove delivered (and pending) notifications that belong to any of the
    /// given conversation ids — used when the user opens that chat.
    func clearNotifications(forConversationIds conversationIds: Set<String>) {
        guard !isRunningTests else { return }
        let targets = Set(conversationIds.filter { !$0.isEmpty })
        guard !targets.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let match = delivered.compactMap { notif -> String? in
                SonarNotificationHandoff.matches(
                    userInfo: notif.request.content.userInfo,
                    conversationIds: targets
                ) ? notif.request.identifier : nil
            }
            if !match.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: match)
            }
        }
        center.getPendingNotificationRequests { pending in
            let match = pending.compactMap { req -> String? in
                SonarNotificationHandoff.matches(
                    userInfo: req.content.userInfo,
                    conversationIds: targets
                ) ? req.identifier : nil
            }
            if !match.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: match)
            }
        }
    }
}
