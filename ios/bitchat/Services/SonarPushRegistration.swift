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
import CryptoKit
import SonarCore

final class SonarPushRegistration {
    static let shared = SonarPushRegistration()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.hedwig.sonar",
        category: "SonarPush"
    )

    private var cachedAPNSToken: Data?
    private var cachedFCMToken: String?
    private var cachedOffer: String?
    private var sonarNode: SonarNode?
    private let queue = DispatchQueue(label: "chat.bitchat.sonar.push.registration")

    /// Persisted fingerprint of the last successful webhook subscription
    /// (sha256 of offer|fcmToken|ndsUrl). Lets us skip redundant re-subscribes.
    private static let webhookMarkerKey = "breez_webhook_marker"

    private var transponderNpub: String {
        Bundle.main.infoDictionary?["TRANSPONDER_NPUB"] as? String ?? ""
    }

    /// Base URL of the Breez NDS, e.g. `https://nds.sonar.hedwig.sh`.
    ///
    /// The value is configured in `Local.xcconfig` as a BARE HOST (no scheme),
    /// because xcconfig treats `//` as a comment and silently truncates
    /// `https://host` to `https:`. We prepend the scheme here and reject the
    /// truncated `https:`/`http:` sentinels so a malformed webhook URL can never
    /// be registered with Boltz (which would leave offline receive broken).
    private var ndsUrl: String {
        let raw = (Bundle.main.infoDictionary?["NDS_URL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "https:", raw != "http:" else { return "" }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        return "https://\(raw)"
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
        // Coordinate offer + token on the serial queue: the webhook can only be
        // (re)subscribed once both are known (the offer keys the idempotency
        // marker). Whichever lands second on the queue triggers the subscribe.
        queue.async {
            self.cachedFCMToken = fcmToken
            guard let offer = self.cachedOffer else {
                Self.log.info("Breez NDS: FCM token ready, waiting for receive offer")
                return
            }
            self.subscribeBreezWebhook(offer: offer, fcmToken: fcmToken, wallet: wallet)
        }
    }

    /// Called from the receiver-advertising flow each time the BOLT12 receive
    /// offer is (re)published. Coordinates the offer with the FCM token — whichever
    /// arrives second triggers the subscribe.
    func ensureBreezWebhook(offer: String, wallet: WalletBridgeService?) {
        queue.async {
            self.cachedOffer = offer
            guard let fcmToken = self.cachedFCMToken else {
                Self.log.info("Breez NDS: receive offer ready, waiting for FCM token")
                return
            }
            self.subscribeBreezWebhook(offer: offer, fcmToken: fcmToken, wallet: wallet)
        }
    }

    func retryBreezWebhookIfNeeded(wallet: WalletBridgeService) {
        queue.async {
            guard let fcmToken = self.cachedFCMToken, let offer = self.cachedOffer else { return }
            self.subscribeBreezWebhook(offer: offer, fcmToken: fcmToken, wallet: wallet)
        }
    }

    func unregister(wallet: WalletBridgeService? = nil) {
        queue.async {
            self.cachedAPNSToken = nil
            self.cachedOffer = nil
        }
        // Force a fresh subscribe next time (e.g. after a wallet/seed change).
        UserDefaults.standard.removeObject(forKey: Self.webhookMarkerKey)
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

    private func subscribeBreezWebhook(offer: String, fcmToken: String, wallet: WalletBridgeService?) {
        guard !ndsUrl.isEmpty else { return }
        guard let wallet else {
            Self.log.info("Breez NDS: wallet not ready, will retry after wallet setup")
            return
        }
        let webhookUrl = "\(ndsUrl)/api/v1/notify?platform=ios&token=\(fcmToken)"
        let marker = Self.webhookMarker(offer: offer, fcmToken: fcmToken, ndsUrl: ndsUrl)
        Task { @MainActor in
            guard case .ready = wallet.state else {
                Self.log.info("Breez NDS: wallet not ready, will retry after wallet setup")
                return
            }
            // Idempotent: skip when offer + token + NDS are unchanged since the last
            // successful subscription.
            if UserDefaults.standard.string(forKey: Self.webhookMarkerKey) == marker {
                return
            }
            do {
                // Force a clean re-subscribe. A plain registerWebhook no-ops when the
                // SDK's local `bolt12_offers.webhook_url` already equals this URL but
                // Boltz still holds `url=None` — the desync that breaks offline receive.
                // unregister clears the local webhook state, register re-PATCHes the
                // offer on Boltz (`update_bolt12_offer`) with the current FCM URL.
                // Matches the misty-breez reference's unregister→register flow.
                try? await wallet.unregisterWebhook()
                try await wallet.registerWebhook(url: webhookUrl)
                UserDefaults.standard.set(marker, forKey: Self.webhookMarkerKey)
                Self.log.info("Breez NDS webhook (re)subscribed for current offer (FCM)")
            } catch {
                Self.log.warning("Breez NDS webhook registration failed: \(error)")
            }
        }
    }

    private static func webhookMarker(offer: String, fcmToken: String, ndsUrl: String) -> String {
        let digest = SHA256.hash(data: Data("\(offer)|\(fcmToken)|\(ndsUrl)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
