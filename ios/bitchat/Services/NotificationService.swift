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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = switch sound {
        case .standard: Self.standardNotificationSound
        case .ble: Self.bleNotificationSound
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

    /// Returns only after UserNotifications accepts the request, or `true`
    /// when durable authorization policy suppresses it. Notification outbox
    /// entries must not be acknowledged on a transient `add` failure, but a
    /// denied/not-yet-determined policy must not create a stale replay backlog.
    func postLocalNotification(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active,
        renderLease: SonarNotificationRenderLease? = nil
    ) async -> Bool {
        guard !isRunningTests else { return false }
        let center = UNUserNotificationCenter.current()
        let authorized = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let allowed: Bool
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    allowed = true
                case .notDetermined, .denied:
                    allowed = false
                @unknown default:
                    allowed = false
                }
                continuation.resume(returning: allowed)
            }
        }
        guard authorized else { return true }
        guard renderLease?.isCurrent ?? true else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel
        if let userInfo { content.userInfo = userInfo }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        return await withCheckedContinuation { continuation in
            let cleanup = {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            let submit = {
                center.add(request) { error in
                    let generationStillCurrent = renderLease?.isCurrent ?? true
                    if !generationStillCurrent { cleanup() }
                    renderLease?.finishSubmission()
                    continuation.resume(
                        returning: error == nil && generationStillCurrent
                    )
                }
            }
            if let renderLease {
                guard renderLease.submitIfCurrent(
                    cleanupOnInvalidation: cleanup,
                    submit
                ) else {
                    continuation.resume(returning: false)
                    return
                }
            } else {
                submit()
            }
        }
    }

    func cancelLocalNotification(identifier: String) {
        guard !isRunningTests else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancelLocalNotificationAccepted(
        identifier: String,
        renderLease: SonarNotificationRenderLease? = nil
    ) async -> Bool {
        guard !isRunningTests else { return false }
        guard let renderLease else {
            cancelLocalNotification(identifier: identifier)
            return true
        }
        let accepted = renderLease.submitIfCurrent(
            cleanupOnInvalidation: {},
            { cancelLocalNotification(identifier: identifier) }
        )
        renderLease.finishSubmission()
        return accepted && renderLease.isCurrent
    }
    
    func sendMentionNotification(
        from sender: String,
        message: String,
        sound: SonarNotificationSound = .standard
    ) {
        let title = "You were mentioned"
        let body = "Open Sonar to read it."
        let identifier = "mention-\(UUID().uuidString)"

        sendLocalNotification(title: title, body: body, identifier: identifier, sound: sound)
    }

    func sendPrivateMessageNotification(
        from sender: String,
        message: String,
        peerID: PeerID,
        sound: SonarNotificationSound = .standard
    ) {
        let title = "New Sonar message"
        let body = "Open Sonar to read it."
        let identifier = "private-\(UUID().uuidString)"
        let userInfo: [String: Any] = [
            SonarNotificationKeys.peerID: peerID.id,
            SonarNotificationKeys.conversationId: peerID.id,
            "senderName": sender,
        ]

        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            userInfo: userInfo,
            sound: sound
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
