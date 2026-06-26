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
    private var sonarNode: SonarNode?
    private let queue = DispatchQueue(label: "chat.bitchat.sonar.push.registration")

    /// Fired (on the main actor) when a *fresh* Breez webhook registration lands —
    /// i.e. the (fcmToken|ndsUrl) binding changed. The host uses it to re-publish a
    /// fresh BOLT12 offer so the new offer is minted *after* the webhook is set and
    /// therefore carries it (#126). One-shot per binding: the marker is offer-
    /// independent, so the offer rotation a re-publish causes can't re-trigger it.
    var onWebhookRegistered: (() -> Void)?

    /// Persisted fingerprint of the last successful webhook registration
    /// (sha256 of fcmToken|ndsUrl). Lets us skip redundant re-registration. Offer-
    /// independent on purpose: the webhook URL doesn't depend on the offer (#126).
    private static let webhookMarkerKey = "breez_webhook_marker"

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
        queue.sync { self.cachedFCMToken = fcmToken }
        // The webhook URL is (ndsUrl + fcmToken) only — it does NOT depend on the
        // receive offer. Bind it as soon as the token + wallet are ready; a fresh
        // binding re-publishes the offer so it is (re)minted under the webhook (#126).
        Task { @MainActor in
            if await self.registerWebhookIfNeeded(wallet: wallet) {
                self.onWebhookRegistered?()
            }
        }
    }

    /// Ensure the Breez NDS webhook is registered with the SDK *before* the BOLT12
    /// receive offer is minted. The SDK's `create_bolt12_offer` snapshots the
    /// current webhook URL at creation time and POSTs the offer to Boltz with it,
    /// so registering first is what makes Boltz store `url=` instead of `None` — the
    /// confirmed root cause of offline-receive failing in #126. Awaited by the
    /// publish flow so the mint that follows carries the webhook.
    @MainActor
    func ensureWebhookRegisteredBeforeOffer(wallet: WalletBridgeService?) async {
        _ = await registerWebhookIfNeeded(wallet: wallet)
    }

    /// Re-attempt registration after the wallet becomes ready (the FCM token is
    /// usually already cached by then). A fresh binding re-publishes the offer.
    func retryBreezWebhookIfNeeded(wallet: WalletBridgeService) {
        Task { @MainActor in
            if await self.registerWebhookIfNeeded(wallet: wallet) {
                self.onWebhookRegistered?()
            }
        }
    }

    func unregister(wallet: WalletBridgeService? = nil) {
        queue.async {
            self.cachedAPNSToken = nil
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

    /// Register the Breez NDS webhook with the SDK, idempotent on (fcmToken|ndsUrl).
    /// Returns true iff a *fresh* registration landed (the binding changed), so the
    /// caller can re-publish a fresh offer that snapshots it.
    ///
    /// The webhook URL is offer-independent. Keying the marker on the offer (as the
    /// old code did) forced a needless re-register on every offer rotation yet still
    /// left a pre-webhook offer on Boltz with `url=None`, because the SDK's
    /// `registerWebhook` only re-PATCHes offers already in its local `bolt12_offers`
    /// table and no-ops on an empty list. Registering here, *before* the next
    /// `createOffer`, is the actual fix for #126: the new offer snapshots this URL
    /// at mint time and Boltz stores `url=`.
    @MainActor
    @discardableResult
    private func registerWebhookIfNeeded(wallet: WalletBridgeService?) async -> Bool {
        guard !ndsUrl.isEmpty else { return false }
        guard let wallet else {
            Self.log.info("Breez NDS: wallet not ready, will retry after wallet setup")
            return false
        }
        guard let fcmToken = queue.sync(execute: { self.cachedFCMToken }) else {
            Self.log.info("Breez NDS: FCM token not ready, will retry after token arrives")
            return false
        }
        guard case .ready = wallet.state else {
            Self.log.info("Breez NDS: wallet not ready, will retry after wallet setup")
            return false
        }
        let webhookUrl = "\(ndsUrl)/api/v1/notify?platform=ios&token=\(fcmToken)"
        let marker = Self.webhookMarker(fcmToken: fcmToken, ndsUrl: ndsUrl)
        if UserDefaults.standard.string(forKey: Self.webhookMarkerKey) == marker {
            return false
        }
        do {
            // unregister→register forces a clean re-PATCH: a plain registerWebhook
            // no-ops when the SDK's local webhook URL already matches. Matches the
            // misty-breez reference flow. The mint that follows snapshots this URL.
            try? await wallet.unregisterWebhook()
            try await wallet.registerWebhook(url: webhookUrl)
            UserDefaults.standard.set(marker, forKey: Self.webhookMarkerKey)
            Self.log.info("Breez NDS webhook registered (FCM); next offer mint will carry it")
            return true
        } catch {
            Self.log.warning("Breez NDS webhook registration failed: \(error)")
            return false
        }
    }

    private static func webhookMarker(fcmToken: String, ndsUrl: String) -> String {
        let digest = SHA256.hash(data: Data("\(fcmToken)|\(ndsUrl)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
