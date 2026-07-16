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

enum NotificationSubmissionOutcome: Equatable {
    case submitted
    case terminallySuppressed
    case retryableFailure
}

final class NotificationService {
    static let shared = NotificationService()
    private static let standardNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_notification.wav")
    )
    private static let bleNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_ble_notification.wav")
    )

    typealias Submitter = (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    typealias Canceller = ([String]) -> Void
    typealias CancelAll = () -> Void
    private let testEnvironment: () -> Bool
    private let submitter: Submitter
    private let canceller: Canceller
    private let cancelAll: CancelAll
    /// Serializes account-generation validation with the synchronous handoff to
    /// UserNotifications. If submission wins a race with panic suspension, the
    /// suspension removes the request and the completion removes it again.
    private let accountFence = NSRecursiveLock()
    private var accountGeneration: UInt64 = 0
    private var accountNotificationsSuspended = false
    /// Platform request identifiers are generation-scoped. Public callers keep
    /// passing stable logical identifiers, but a callback from a retired account
    /// can only cancel the exact request it submitted and can never target a
    /// replacement account that reused the same logical identifier.
    private var accountNotificationIDs: [UInt64: Set<String>] = [:]

    /// Returns true if running in test environment (XCTest, Swift Testing, or CI)
    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil ||
               env["XCTestConfigurationFilePath"] != nil ||
               env["XCTestBundlePath"] != nil ||
               env["GITHUB_ACTIONS"] != nil ||
               env["CI"] != nil
    }

    init(
        testEnvironment: @escaping () -> Bool = { NotificationService.isRunningTests },
        submitter: @escaping Submitter = { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        },
        canceller: @escaping Canceller = { identifiers in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        },
        cancelAll: @escaping CancelAll = {
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
        }
    ) {
        self.testEnvironment = testEnvironment
        self.submitter = submitter
        self.canceller = canceller
        self.cancelAll = cancelAll
    }

    /// Synchronous account boundary used by the panic redaction path. Every
    /// request rendered by the retired generation is cancelled, including one
    /// whose platform callback is still suspended.
    func suspendAccountNotifications() {
        accountFence.lock()
        accountNotificationsSuspended = true
        accountGeneration &+= 1
        let identifiers = Array(Set(accountNotificationIDs.values.flatMap { $0 }))
        accountNotificationIDs.removeAll()
        // In-memory identifiers cannot cover delivered requests from an earlier
        // process. Every app notification is account-bound, so panic removes the
        // whole app-owned notification namespace while the submission fence is
        // held. Retired callbacks still cancel their exact generation-scoped ID.
        cancelAll()
        if !identifiers.isEmpty { canceller(identifiers) }
        accountFence.unlock()
    }

    /// Reopening notification rendering before the durable panic journal is
    /// gone could publish old-account UI into a replacement account.
    @discardableResult
    func reactivateAccountNotifications(
        markerPending: () -> Bool = { PanicWipeIntent.isPending }
    ) -> Bool {
        accountFence.lock()
        defer { accountFence.unlock() }
        guard !markerPending() else { return false }
        accountGeneration &+= 1
        accountNotificationsSuspended = false
        return true
    }

    func requestAuthorization() {
        guard !testEnvironment() else { return }
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
        guard !testEnvironment() else { return }
        accountFence.lock()
        guard !accountNotificationsSuspended else {
            accountFence.unlock()
            return
        }
        let generation = accountGeneration
        let platformIdentifier = platformIdentifier(
            logicalIdentifier: identifier,
            generation: generation
        )
        let request = makeRequest(
            title: title,
            body: body,
            identifier: platformIdentifier,
            userInfo: userInfo,
            interruptionLevel: interruptionLevel,
            sound: sound
        )
        accountNotificationIDs[generation, default: []].insert(platformIdentifier)
        submitter(request) { [weak self] error in
            self?.completeFireAndForgetSubmission(
                platformIdentifier: platformIdentifier,
                generation: generation,
                error: error
            )
        }
        accountFence.unlock()
    }

    /// Await the actual notification-center admission callback. A transient
    /// submission error leaves the receive effect durable and therefore withholds
    /// the BLE ACK; test mode is an explicit terminal suppression.
    func submitLocalNotification(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active,
        sound: SonarNotificationSound = .standard
    ) async -> NotificationSubmissionOutcome {
        guard !testEnvironment() else { return .terminallySuppressed }
        return await withCheckedContinuation { continuation in
            accountFence.lock()
            guard !accountNotificationsSuspended else {
                accountFence.unlock()
                continuation.resume(returning: .retryableFailure)
                return
            }
            let generation = accountGeneration
            let platformIdentifier = platformIdentifier(
                logicalIdentifier: identifier,
                generation: generation
            )
            // Rendering occurs only after the generation lease is admitted, so
            // peer identifiers never escape through a suspended account.
            let request = makeRequest(
                title: title,
                body: body,
                identifier: platformIdentifier,
                userInfo: userInfo,
                interruptionLevel: interruptionLevel,
                sound: sound
            )
            accountNotificationIDs[generation, default: []].insert(platformIdentifier)
            submitter(request) { [weak self] error in
                let outcome = self?.completeAwaitedSubmission(
                    platformIdentifier: platformIdentifier,
                    generation: generation,
                    error: error
                ) ?? .retryableFailure
                continuation.resume(returning: outcome)
            }
            accountFence.unlock()
        }
    }

    private func completeFireAndForgetSubmission(
        platformIdentifier: String,
        generation: UInt64,
        error: Error?
    ) {
        accountFence.lock()
        let current = !accountNotificationsSuspended && generation == accountGeneration
        if error != nil {
            accountNotificationIDs[generation]?.remove(platformIdentifier)
        }
        if !current { canceller([platformIdentifier]) }
        accountFence.unlock()
    }

    private func completeAwaitedSubmission(
        platformIdentifier: String,
        generation: UInt64,
        error: Error?
    ) -> NotificationSubmissionOutcome {
        accountFence.lock()
        defer { accountFence.unlock() }
        let current = !accountNotificationsSuspended && generation == accountGeneration
        guard current else {
            canceller([platformIdentifier])
            return .retryableFailure
        }
        if error == nil { return .submitted }
        accountNotificationIDs[generation]?.remove(platformIdentifier)
        if let nsError = error as NSError?,
           nsError.domain == UNErrorDomain,
           nsError.code == UNError.Code.notificationsNotAllowed.rawValue {
            // The user/system explicitly disabled notifications. Retrying
            // cannot make this receive effect visible, so suppress it
            // terminally instead of withholding BLE delivery forever.
            return .terminallySuppressed
        }
        return .retryableFailure
    }

    private func platformIdentifier(
        logicalIdentifier: String,
        generation: UInt64
    ) -> String {
        "\(logicalIdentifier).account-generation-\(generation)"
    }

    private func makeRequest(
        title: String,
        body: String,
        identifier: String,
        userInfo: [String: Any]?,
        interruptionLevel: UNNotificationInterruptionLevel,
        sound: SonarNotificationSound
    ) -> UNNotificationRequest {
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

        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )
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
        messageID: String? = nil,
        sound: SonarNotificationSound = .standard
    ) async -> NotificationSubmissionOutcome {
        let title = "New Sonar message"
        let body = "Open Sonar to read it."
        // Stable receive IDs make crash replay replace the same notification
        // instead of duplicating it before the processed marker is durable.
        let identifier = "private-\(messageID ?? UUID().uuidString)"
        let userInfo = ["peerID": peerID.id, "senderName": sender]

        return await submitLocalNotification(
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
}
