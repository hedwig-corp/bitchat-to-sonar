//
// SonarPushRegistration.swift
// bitchat
//
// Registers the device's APNS token with both notification servers:
//   1. Transponder — MIP-05 encrypted gift wrap (chat/call wakeups)
//   2. Breez NDS   — webhook URL (wallet wakeups, silent only)
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import os
import SonarCore

final class SonarPushRegistration {
    static let shared = SonarPushRegistration()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.hedwig.sonar",
        category: "SonarPush"
    )

    private var cachedAPNSToken: Data?
    private var cachedFCMToken: String?
    private var sonarNode: SonarNode?
    private let queue = DispatchQueue(label: "chat.bitchat.sonar.push.registration")

    private var transponderNpub: String {
        Bundle.main.infoDictionary?["TRANSPONDER_NPUB"] as? String ?? ""
    }

    private var ndsUrl: String {
        Bundle.main.infoDictionary?["NDS_URL"] as? String ?? ""
    }

    private init() {}

    // MARK: - Public

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.log.info("APNS token collected (\(hex.prefix(8))...)")
        queue.async { self.cachedAPNSToken = deviceToken }
        // Transponder (chat/calls) uses the raw APNs token. The Breez NDS uses the
        // Firebase FCM token instead — registered via didReceiveFCMToken.
        registerTransponder(token: deviceToken)
    }

    /// Firebase FCM token for the Breez NDS webhook. `breez/notify` is FCM-only;
    /// Firebase bridges FCM → APNs on iOS (the APNs key lives in the Firebase
    /// Console). Matches Sonar Android and Unify.
    func didReceiveFCMToken(_ fcmToken: String, wallet: WalletBridgeService?) {
        Self.log.info("FCM token collected (\(fcmToken.prefix(8))...)")
        queue.async { self.cachedFCMToken = fcmToken }
        registerBreezWebhook(fcmToken: fcmToken, wallet: wallet)
    }

    func retryBreezWebhookIfNeeded(wallet: WalletBridgeService) {
        guard let fcmToken = cachedFCMToken else { return }
        registerBreezWebhook(fcmToken: fcmToken, wallet: wallet)
    }

    func unregister(wallet: WalletBridgeService? = nil) {
        queue.async { self.cachedAPNSToken = nil }
        if let wallet {
            Task { @MainActor in
                try? await wallet.unregisterWebhook()
            }
        }
        Self.log.info("Unregistered from push servers")
    }

    /// Set the SonarNode once it's initialized. Retries transponder registration
    /// if an APNS token was already collected.
    func setSonarNode(_ node: SonarNode) {
        queue.async {
            self.sonarNode = node
            if let token = self.cachedAPNSToken {
                self.registerTransponder(token: token)
            }
        }
    }

    // MARK: - Private

    private static let maxRetries = 3

    private func registerTransponder(token: Data) {
        guard !transponderNpub.isEmpty else { return }
        guard let node = sonarNode else {
            Self.log.info("Transponder: SonarNode not ready, will retry after setSonarNode")
            return
        }
        let npub = self.transponderNpub
        DispatchQueue.global(qos: .utility).async {
            var backoff: UInt32 = 2
            for attempt in 1...Self.maxRetries {
                do {
                    try node.registerPushToken(
                        platform: "apns",
                        token: token,
                        serverNpub: npub
                    )
                    Self.log.info("Transponder: MIP-05 push token registered")
                    return
                } catch {
                    Self.log.warning("Transponder registration attempt \(attempt)/\(Self.maxRetries) failed: \(error)")
                    if attempt < Self.maxRetries { sleep(backoff) }
                    backoff *= 2
                }
            }
        }
    }

    private func registerBreezWebhook(fcmToken: String, wallet: WalletBridgeService? = nil) {
        guard !ndsUrl.isEmpty else { return }
        guard let wallet else {
            Self.log.info("Breez NDS: wallet not ready, will retry after wallet setup")
            return
        }
        let webhookUrl = "\(ndsUrl)/api/v1/notify?platform=ios&token=\(fcmToken)"
        Task { @MainActor in
            guard case .ready = wallet.state else {
                Self.log.info("Breez NDS: wallet not ready, will retry after wallet setup")
                return
            }
            do {
                try await wallet.registerWebhook(url: webhookUrl)
                Self.log.info("Breez NDS webhook registered (FCM)")
            } catch {
                Self.log.warning("Breez NDS webhook registration failed: \(error)")
            }
        }
    }
}

#endif
