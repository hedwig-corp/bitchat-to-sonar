//
// SonarNotificationPrefsTests.swift
// bitchatTests
//
// Regression: mesh/mention notifications must honor Show names / Message
// preview settings via SonarLocalNotificationRouter (not hard-coded generic
// copy). Fixes the gap introduced when PR #58 replaced rich local copy with
// always-private placeholders.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import UserNotifications
@testable import Sonar

struct SonarNotificationPrefsTests {

    @Test("preference defaults match Settings: names on, preview off")
    func preferenceDefaults() {
        let suite = "sonar.notif.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = SonarNotificationPreferenceStore.load(from: defaults)
        #expect(prefs.enabled == true)
        #expect(prefs.showNames == true)
        #expect(prefs.showPreview == false)
    }

    @Test("preference store reads explicit toggles")
    func preferenceStoreReadsToggles() {
        let suite = "sonar.notif.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: SonarNotificationPreferenceStore.showNamesKey)
        defaults.set(true, forKey: SonarNotificationPreferenceStore.showPreviewKey)

        let prefs = SonarNotificationPreferenceStore.load(from: defaults)
        #expect(prefs.showNames == false)
        #expect(prefs.showPreview == true)
    }

    @Test("private-message router shows sender by default and hides preview")
    func privateMessageRespectsDefaultPrivacy() {
        let prefs = SonarLocalNotificationPrefs(
            enabled: true,
            showNames: true,
            showPreview: false,
            showPaymentAmount: true
        )
        let routed = SonarLocalNotificationRouter.make(
            idKey: "peer-1",
            kind: .message,
            conversationTitle: "Alice",
            senderName: "Alice",
            preview: "secret hello",
            prefs: prefs
        )
        #expect(routed?.title == "Alice")
        #expect(routed?.body == "Open Sonar to read it.")
    }

    @Test("private-message router shows preview when setting is on")
    func privateMessageRespectsPreviewOptIn() {
        let prefs = SonarLocalNotificationPrefs(
            enabled: true,
            showNames: true,
            showPreview: true,
            showPaymentAmount: true
        )
        // Pin the mesh call-site seam (`NotificationService.routedPrivateMessageNotification`),
        // not only the bare router — R-001 style: helpers can stay green while the
        // instance method hard-codes private copy again.
        let routed = NotificationService.routedPrivateMessageNotification(
            sender: "Alice",
            message: "secret hello",
            peerID: "peer-1",
            prefs: prefs
        )
        #expect(routed?.title == "Alice")
        #expect(routed?.body == "secret hello")
        #expect(routed?.identifier == "private-sonar-message-peer-1")
    }

    @Test("mesh mention seam honors preview opt-in")
    func mentionSeamRespectsPreviewOptIn() {
        let prefs = SonarLocalNotificationPrefs(
            enabled: true,
            showNames: true,
            showPreview: true,
            showPaymentAmount: true
        )
        let routed = NotificationService.routedMentionNotification(
            sender: "Bob",
            message: "hey @you",
            prefs: prefs,
            idKey: "mention-1"
        )
        // Core renders the mention title as "<sender> mentioned you"
        // (notification.rs since #144); the seam adds the mention- prefix.
        #expect(routed?.title == "Bob mentioned you")
        #expect(routed?.body == "hey @you")
        #expect(routed?.identifier.hasPrefix("mention-") == true)
    }

    @Test("private-message router hides names when setting is off")
    func privateMessageRespectsNamesOff() {
        let prefs = SonarLocalNotificationPrefs(
            enabled: true,
            showNames: false,
            showPreview: true,
            showPaymentAmount: true
        )
        let routed = SonarLocalNotificationRouter.make(
            idKey: "peer-1",
            kind: .message,
            conversationTitle: "Alice",
            senderName: "Alice",
            preview: "secret hello",
            prefs: prefs
        )
        #expect(routed?.title == "New Sonar message")
        #expect(routed?.body == "secret hello")
    }

    @Test("disabled notifications suppress the envelope")
    func disabledSuppresses() {
        let prefs = SonarLocalNotificationPrefs(
            enabled: false,
            showNames: true,
            showPreview: true,
            showPaymentAmount: true
        )
        let routed = SonarLocalNotificationRouter.make(
            idKey: "peer-1",
            kind: .message,
            conversationTitle: "Alice",
            senderName: "Alice",
            preview: "secret hello",
            prefs: prefs
        )
        #expect(routed == nil)
    }

    @Test("unread delta ignores unknown keys until baseline is hydrated")
    func unreadDeltaRequiresHydratedBaseline() {
        let after = SonarPushUnreadDelta.Fingerprint(
            unread: 1,
            latestAt: Date(timeIntervalSince1970: 100),
            content: "hello"
        )
        #expect(
            SonarPushUnreadDelta.isNewlyAdvanced(
                groupId: "g1",
                after: after,
                before: [:],
                baselineHydrated: false
            ) == false
        )
        #expect(
            SonarPushUnreadDelta.isNewlyAdvanced(
                groupId: "g1",
                after: after,
                before: [:],
                baselineHydrated: true
            ) == true
        )
    }

    @Test("drain preview matching handles core truncation ellipsis")
    func drainPreviewMatchesTruncation() {
        let full = String(repeating: "a", count: 150)
        let preview = String(full.prefix(100)) + "…"
        #expect(SonarPushWakeDedup.matchesPreview(fullContent: full, preview: preview))
        #expect(SonarPushWakeDedup.matchesPreview(fullContent: "hello", preview: "hello"))
        #expect(!SonarPushWakeDedup.matchesPreview(fullContent: "hello", preview: "goodbye"))
        #expect(!SonarPushWakeDedup.matchesPreview(fullContent: full, preview: "bbbb…"))
    }

    @Test("unread delta does not re-alert unchanged stale unread")
    func unreadDeltaSkipsUnchangedStale() {
        let stamp = Date(timeIntervalSince1970: 100)
        let prior = SonarPushUnreadDelta.Fingerprint(
            unread: 2,
            latestAt: stamp,
            content: "old"
        )
        #expect(
            SonarPushUnreadDelta.isNewlyAdvanced(
                groupId: "g1",
                after: prior,
                before: ["g1": prior],
                baselineHydrated: true
            ) == false
        )
        #expect(
            SonarPushUnreadDelta.isNewlyAdvanced(
                groupId: "g1",
                after: SonarPushUnreadDelta.Fingerprint(
                    unread: 3,
                    latestAt: stamp,
                    content: "old"
                ),
                before: ["g1": prior],
                baselineHydrated: true
            ) == true
        )
    }

    #if os(iOS)
    @Test("app-generated Marmot notifications retain forced catch-up identity")
    func localMarmotWakeMarkerSurvivesRouting() {
        let routed = SonarLocalNotificationRouter.make(
            idKey: "msg-1",
            kind: .message,
            conversationTitle: "Alice",
            preview: "hello",
            prefs: SonarLocalNotificationPrefs(),
            userInfo: [SonarNotificationKeys.marmotWake: true]
        )
        #expect(SonarNotificationHandoff.isMarmotWake(from: routed!.userInfo))
        #expect(
            SonarNotificationHandoff.isMarmotWake(
                from: [SonarNotificationKeys.marmotWake: NSNumber(value: true)]
            )
        )
        #expect(
            SonarNotificationHandoff.isMarmotWake(
                from: [SonarNotificationKeys.marmotWake: false]
            ) == false
        )
    }

    @Test("NSE placeholder wipe keeps ids that arrived after wake start")
    func nsePlaceholderWipeRespectsWakeSnapshot() {
        let toRemove = SonarPushProcessor.nsePlaceholderIdsToRemove(
            deliveredPlaceholderIds: ["nse-a", "nse-b-new"],
            allowedFromWakeStart: ["nse-a"]
        )
        #expect(toRemove == ["nse-a"])
        #expect(
            SonarPushProcessor.nsePlaceholderIdsToRemove(
                deliveredPlaceholderIds: ["nse-b-new"],
                allowedFromWakeStart: []
            ).isEmpty
        )
    }

    @Test("NSE placeholder detection ignores router privacy-fallback copy")
    func nsePlaceholderMatchesIdentityNotCopy() {
        // Router privacy fallback (names off, preview off) uses the same
        // title/body as the NSE placeholder — cleanup must not key on those.
        let prefs = SonarLocalNotificationPrefs(
            enabled: true,
            showNames: false,
            showPreview: false,
            showPaymentAmount: true
        )
        let routed = SonarLocalNotificationRouter.make(
            idKey: "peer-1",
            kind: .message,
            conversationTitle: "Alice",
            senderName: "Alice",
            preview: "secret hello",
            prefs: prefs
        )
        #expect(routed?.title == "New Sonar message")
        #expect(routed?.body == "Open Sonar to read it.")

        let plain = UNMutableNotificationContent()
        plain.title = routed!.title
        plain.body = routed!.body
        #expect(SonarPushProcessor.isNSEPlaceholder(plain) == false)

        let nse = UNMutableNotificationContent()
        nse.title = "Sonar"
        nse.body = "Open Sonar to read it."
        nse.userInfo = [SonarPushProcessor.nsePlaceholderUserInfoKey: true]
        #expect(SonarPushProcessor.isNSEPlaceholder(nse) == true)
    }

    @Test("host replaces NSE-decorated banners by message or conversation id")
    func nseOwnedReplaceMatchesTipIdentity() {
        let rows: [(id: String, messageId: String?, conversationId: String?)] = [
            ("apns-1", "msg-aaa", "marmot:g1"),
            ("apns-2", "msg-bbb", "marmot:g2"),
            ("local-extra", nil, "marmot:g1"),
        ]
        #expect(
            SonarPushProcessor.nseOwnedIdsToRemove(
                delivered: rows,
                messageIdHex: "msg-aaa",
                conversationId: nil
            ) == ["apns-1"]
        )
        #expect(
            Set(
                SonarPushProcessor.nseOwnedIdsToRemove(
                    delivered: rows,
                    messageIdHex: nil,
                    conversationId: "marmot:g1"
                )
            ) == Set(["apns-1", "local-extra"])
        )

        let decorated = UNMutableNotificationContent()
        decorated.userInfo = [SonarPushProcessor.nseDecoratedUserInfoKey: true]
        #expect(SonarPushProcessor.isNSEDecorated(decorated) == true)
        #expect(SonarPushProcessor.isNSEOwned(decorated) == true)
        #expect(SonarPushProcessor.isNSEPlaceholder(decorated) == false)
    }
    #endif
}
