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
    /// Incoming money. Distinct from `.standard`/`.ble` so a payment does not
    /// arrive wearing the chat tone — a mesh payment used to ring the Bluetooth
    /// message sound, which is a property of the transport, not of the event.
    case payment
    /// Deliver visually with no sound.
    case silent
}

/// UserInfo / identifier keys shared by Sonar local notifications and the
/// tap handoff in `NotificationDelegate`.
enum SonarNotificationKeys {
    static let conversationId = "sonarConversationId"
    static let peerID = "peerID"
    /// Stable local message id for Jump open-action (#372). Optional.
    static let messageId = "sonarMessageId"
    /// Marks app-generated Marmot/Transponder banners whose tap must force
    /// catch-up even though the original remote-push keys are no longer present.
    static let marmotWake = "sonarMarmotWake"
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

    static func messageId(from userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo[SonarNotificationKeys.messageId] as? String else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isMarmotWake(from userInfo: [AnyHashable: Any]) -> Bool {
        if let flag = userInfo[SonarNotificationKeys.marmotWake] as? Bool { return flag }
        if let flag = userInfo[SonarNotificationKeys.marmotWake] as? NSNumber { return flag.boolValue }
        return false
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
    /// TODO(assets): shares the message tone until a dedicated `sonar_payment`
    /// master exists (see assets/notifications/README.md for the mastering +
    /// conversion step). Routed through its own constant so adding the file is
    /// a one-line change here — and note the appex has NO synchronized-folder
    /// sync, so a new sound must be added to the NSE target explicitly or it
    /// is silently silent on the killed-app path (prior incident).
    private static let paymentNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_notification.wav")
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
    
    /// Category + thread identifiers for a payment banner.
    ///
    /// `sonar.payment` is registered in `registerNotificationCategories()`.
    /// Before this existed NOTHING called `setNotificationCategories`, so the
    /// NSE's `categoryIdentifier = "sonar.message"` referred to a category that
    /// did not exist and iOS silently ignored it.
    ///
    /// The thread identifier is scoped `sonar.payment.<conversationId>`, not a
    /// single global bucket: payments group away from the chat stack (so money
    /// never collapses into the message thread) while still grouping per
    /// person, and `clearNotifications(forConversationIds:)` keeps working
    /// unchanged because it matches on `userInfo`, not on the thread.
    static let paymentCategoryIdentifier = "sonar.payment"
    static let messageCategoryIdentifier = "sonar.message"

    static func paymentThreadIdentifier(conversationId: String?) -> String {
        guard let conversationId, !conversationId.isEmpty else { return paymentCategoryIdentifier }
        return "\(paymentCategoryIdentifier).\(conversationId)"
    }

    /// Register the categories the app and the NSE reference. Must run before
    /// any notification is posted, so it lives next to the delegate assignment
    /// at launch. Purely declarative — no actions attached yet; the categories
    /// exist so iOS honours the identifiers and so future actions ("Open
    /// wallet") have somewhere to hang.
    func registerNotificationCategories() {
        let payment = UNNotificationCategory(
            identifier: Self.paymentCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let message = UNNotificationCategory(
            identifier: Self.messageCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([payment, message])
    }

    /// Post an already-routed notification with the presentation its KIND
    /// requires, rather than the presentation its transport implies.
    ///
    /// Exists so the payment-vs-message decision lives in exactly one place.
    /// Three call sites need it — the live Marmot path and both push-wake
    /// drains — and three copies of "is this a payment" is precisely how the
    /// notification paths drifted apart before (mesh payments ringing the
    /// Bluetooth chat tone, one path honouring a kind the others ignored).
    func sendRoutedNotification(
        kind: SonarLocalNotificationKind,
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]?,
        conversationId: String?,
        sound: SonarNotificationSound
    ) {
        let isPayment = kind == .payment
        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            userInfo: userInfo,
            // Money is the one chat event worth breaching Focus for. Needs the
            // time-sensitive entitlement; without it iOS silently downgrades to
            // `.active`, i.e. today's behaviour, so this cannot regress.
            interruptionLevel: isPayment ? .timeSensitive : .active,
            sound: isPayment ? .payment : sound,
            categoryIdentifier: isPayment
                ? Self.paymentCategoryIdentifier
                : Self.messageCategoryIdentifier,
            threadIdentifier: isPayment
                ? Self.paymentThreadIdentifier(conversationId: conversationId)
                : nil,
            subtitle: isPayment ? "Sonar wallet" : nil
        )
    }

    func sendLocalNotification(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active,
        sound: SonarNotificationSound = .standard,
        categoryIdentifier: String? = nil,
        threadIdentifier: String? = nil,
        subtitle: String? = nil
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
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
        if let threadIdentifier { content.threadIdentifier = threadIdentifier }
        content.sound = switch sound {
        case .standard: Self.standardNotificationSound
        case .ble: Self.bleNotificationSound
        case .trill: Self.trillNotificationSound
        case .payment: Self.paymentNotificationSound
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
        messageId: String? = nil,
        sound: SonarNotificationSound = .standard
    ) {
        // Callers pass the real sender + body; never discard them for a
        // hard-coded privacy fallback. The router applies Show names /
        // Message preview (and the master Notifications toggle).
        guard let routed = Self.routedPrivateMessageNotification(
            sender: sender,
            message: message,
            peerID: peerID.id,
            prefs: SonarNotificationPreferenceStore.loadMerged(),
            messageId: messageId
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
        prefs: SonarLocalNotificationPrefs,
        messageId: String? = nil
    ) -> SonarLocalNotification? {
        var userInfo: [String: Any] = [
            SonarNotificationKeys.peerID: peerID,
            SonarNotificationKeys.conversationId: peerID,
        ]
        if prefs.showNames {
            userInfo["senderName"] = sender
        }
        if let messageId, !messageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo[SonarNotificationKeys.messageId] = messageId
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
