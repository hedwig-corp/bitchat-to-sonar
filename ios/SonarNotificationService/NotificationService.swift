//
// NotificationService.swift
// SonarNotificationService
//
// Dual-path Notification Service Extension (White Noise / Signal shape):
//   - Transponder (Marmot): open App Group chat DB, bounded frozen-cursor
//     catch-up, decorate the banner from local decrypted state.
//   - Breez NDS: wake the Breez SDK for offline BOLT12 / swap handling.
// Never initialize both SDKs in one wake (memory budget).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BreezSDKLiquid
import Darwin
import Foundation
import Security
import SonarCore
import UserNotifications
import os

class NotificationService: SDKNotificationService {

    private static let appGroupId = "group.sh.hedwig.sonar"
    private static let notificationsEnabledKey = "sonar.notifications.enabled"
    private static let showNamesKey = "sonar.notifications.showNames"
    private static let showPreviewKey = "sonar.notifications.showPreview"
    private static let nsecKeychainKey = "identity_marmot-nsec"
    private static let dbKeychainKey = "identity_marmot-db-key"
    private static let keychainService = "sh.hedwig.sonar"
    private static let marmotConversationPrefix = "marmot:"
    private static let conversationIdKey = "sonarConversationId"
    /// White Noise uses ~8s; leave headroom for decorate + avatar-free finish.
    private static let marmotWakeWaitMs: UInt64 = 8_000
    private static let maxAdditionalPresentations = 3
    private static let defaultRelayUrls = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.kaleidoswap.com",
        "wss://nostr.relay.hedwig.sh",
    ]
    private static let log = OSLog(subsystem: "sh.hedwig.sonar", category: "NSE")
    private static let notificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_notification.wav")
    )

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var hydrateTask: Task<Void, Never>?
    private let wakeNodeLock = NSLock()
    private var marmotWakeNode: SonarNode?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if Self.isTransponderPush(request.content.userInfo) {
            os_log("NSE: handling Transponder Marmot push",
                   log: Self.log, type: .info)
            self.contentHandler = contentHandler
            let content = Self.mutableContent(for: request)
            bestAttemptContent = content
            guard Self.transponderNotificationsEnabled() else {
                os_log("NSE: suppressing Transponder notification by user preference",
                       log: Self.log, type: .info)
                Self.suppressTransponderNotification(content)
                finish(with: content)
                return
            }
            Self.configureTransponderNotification(content)
            hydrateTask = Task { [weak self] in
                await self?.hydrateMarmotAndDecorate()
            }
            return
        }

        #if DEBUG
        os_log("NSE: didReceive push, userInfo=%{public}@",
               log: Self.log, type: .info, String(describing: request.content.userInfo))
        setServiceLogger(logger: NSEBreezLogger())
        #endif
        super.didReceive(request, withContentHandler: contentHandler)
    }

    override func serviceExtensionTimeWillExpire() {
        hydrateTask?.cancel()
        releaseMarmotWakeNode()
        #if DEBUG
        Self.logResidentMemory("expire")
        #endif
        if let content = bestAttemptContent {
            Self.configureTransponderNotification(content)
            finish(with: content)
        }
        super.serviceExtensionTimeWillExpire()
    }

    // MARK: - Marmot hydrate (Transponder)

    private func hydrateMarmotAndDecorate() async {
        guard let content = bestAttemptContent else {
            finish(with: UNMutableNotificationContent())
            return
        }
        do {
            let notifications = try await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return [DrainNotificationInfo]() }
                return try self.collectMarmotNotificationsAfterWake()
            }.value
            #if DEBUG
            Self.logResidentMemory("after-wake")
            #endif
            guard !Task.isCancelled else {
                releaseMarmotWakeNode()
                finish(with: content)
                return
            }
            if notifications.isEmpty {
                os_log("NSE: Marmot wake drained 0 notifications — keeping generic banner",
                       log: Self.log, type: .info)
                releaseMarmotWakeNode()
                finish(with: content)
                return
            }
            let prefs = Self.notificationPrefs()
            let primary = notifications[0]
            Self.apply(
                notification: primary,
                to: content,
                prefs: prefs
            )
            let extras = Array(notifications.dropFirst().prefix(Self.maxAdditionalPresentations))
            for extra in extras {
                Self.postAdditionalLocalNotification(extra, prefs: prefs)
            }
            os_log("NSE: Marmot wake decorated primary + %d additional",
                   log: Self.log, type: .info, extras.count)
            releaseMarmotWakeNode()
            finish(with: content)
        } catch {
            os_log("NSE: Marmot wake failed — %{private}@ — keeping generic banner",
                   log: Self.log, type: .error, String(describing: error))
            releaseMarmotWakeNode()
            finish(with: content)
        }
    }

    /// Blocking UniFFI work — always call off the main actor.
    /// Main app owns App Group migration; NSE never creates an empty SQLCipher DB.
    /// Skips when the main app holds `MarmotStoreLock` (no concurrent writers).
    private func collectMarmotNotificationsAfterWake() throws -> [DrainNotificationInfo] {
        guard let nsec = Self.readKeychainString(account: Self.nsecKeychainKey),
              let dbKeyHex = Self.readKeychainString(account: Self.dbKeychainKey),
              !nsec.isEmpty,
              dbKeyHex.count == 64
        else {
            throw NSEMarmotError.missingCredentials
        }
        let dbURL = try Self.existingMarmotDatabaseURL()
        guard let storeLock = MarmotStoreLock.tryAcquireExclusive() else {
            throw NSEMarmotError.storeBusy
        }
        defer { storeLock.release() }
        let identity = try SonarIdentity.import(nsec: nsec)
        let node = try SonarNode.connect(
            identity: identity,
            relayUrls: Self.defaultRelayUrls,
            dbPath: dbURL.path,
            dbKeyHex: dbKeyHex
        )
        wakeNodeLock.lock()
        marmotWakeNode = node
        wakeNodeLock.unlock()
        return try node.collectNotificationsAfterWake(maxWaitMs: Self.marmotWakeWaitMs)
    }

    private func releaseMarmotWakeNode() {
        wakeNodeLock.lock()
        marmotWakeNode = nil
        wakeNodeLock.unlock()
    }

    /// Require an existing shared DB — never mkdir+connect into a missing path
    /// (that would mint an empty SQLCipher store and orphan Application Support history).
    private static func existingMarmotDatabaseURL() throws -> URL {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            throw NSEMarmotError.appGroupUnavailable
        }
        let dir = group.appendingPathComponent("sonar-marmot", isDirectory: true)
        let db = dir.appendingPathComponent("marmot.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw NSEMarmotError.sharedDatabaseMissing
        }
        guard databaseIsBackgroundSafe(dir) else {
            throw NSEMarmotError.databaseLocked
        }
        return db
    }

    #if DEBUG
    private static func logResidentMemory(_ label: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let mb = Double(info.resident_size) / 1_048_576.0
        os_log("NSE RSS[%{public}@]=%.1f MB", log: log, type: .info, label, mb)
    }
    #endif

    private static func apply(
        notification: DrainNotificationInfo,
        to content: UNMutableNotificationContent,
        prefs: NSENotificationPrefs
    ) {
        let groupName = notification.groupName.isEmpty ? nil : notification.groupName
        let sender = prefs.showNames
            ? shortLabel(for: notification.senderNpub)
            : nil
        let title: String
        if let groupName, let sender {
            title = "\(sender) in \(groupName)"
        } else if let groupName {
            title = groupName
        } else if let sender {
            title = sender
        } else {
            title = "New Sonar message"
        }
        let body: String
        if prefs.showPreview, !notification.contentPreview.isEmpty {
            body = notification.contentPreview
        } else {
            body = "Open Sonar to read it."
        }
        content.title = title
        content.body = body
        content.sound = notificationSound
        content.categoryIdentifier = "sonar.message"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }
        var userInfo = content.userInfo
        if !notification.groupIdHex.isEmpty {
            userInfo[conversationIdKey] = marmotConversationPrefix + notification.groupIdHex
        }
        content.userInfo = userInfo
    }

    private static func postAdditionalLocalNotification(
        _ notification: DrainNotificationInfo,
        prefs: NSENotificationPrefs
    ) {
        let content = UNMutableNotificationContent()
        apply(notification: notification, to: content, prefs: prefs)
        let id = "sonar-nse-\(notification.groupIdHex)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func shortLabel(for npub: String) -> String {
        let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 16 else { return trimmed }
        return String(trimmed.prefix(12)) + "…"
    }

    private func finish(with content: UNNotificationContent) {
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        hydrateTask = nil
        handler?(content)
    }

    // MARK: - Keychain (shared with main app)

    private static func readKeychainString(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Prefer the App Group access group (matches KeychainManager), then
        // try without — never mint a replacement identity from the NSE.
        for accessGroup in [appGroupId, nil as String?] {
            var q = query
            if let accessGroup {
                q[kSecAttrAccessGroup as String] = accessGroup
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                return value
            }
        }
        // Also try team-prefixed default access group via empty query (no group).
        return nil
    }

    // MARK: - Breez (NDS)

    override func getConnectRequest() -> ConnectRequest? {
        guard let defaults = UserDefaults(suiteName: Self.appGroupId),
              let apiKey = defaults.string(forKey: "breez_api_key"),
              let seedHex = defaults.string(forKey: "breez_seed_hex"),
              let seed = Self.bytes(fromHex: seedHex)
        else {
            os_log("NSE: getConnectRequest -> MISSING creds in App Group (api/seed)",
                   log: Self.log, type: .error)
            return nil
        }
        os_log("NSE: getConnectRequest -> creds OK, connecting Breez",
               log: Self.log, type: .info)

        let mainnet = defaults.bool(forKey: "breez_mainnet")
        let network: LiquidNetwork = mainnet ? .mainnet : .testnet

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
        else {
            return nil
        }
        let workingDir = container
            .appendingPathComponent("breez-sdk", isDirectory: true)
            .appendingPathComponent(mainnet ? "mainnet" : "testnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        let dbProtection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        try? FileManager.default.setAttributes(dbProtection, ofItemAtPath: workingDir.path)
        for file in (try? FileManager.default.contentsOfDirectory(
            at: workingDir, includingPropertiesForKeys: nil
        )) ?? [] {
            try? FileManager.default.setAttributes(dbProtection, ofItemAtPath: file.path)
        }

        guard Self.databaseIsBackgroundSafe(workingDir) else {
            os_log("NSE: Breez store still .complete (locked, pre-heal) — deferring connect to avoid SIGBUS/0xdead10cc",
                   log: Self.log, type: .error)
            return nil
        }

        do {
            var config = try defaultConfig(network: network, breezApiKey: apiKey)
            config.workingDir = workingDir.path
            config.syncServiceUrl = nil
            return ConnectRequest(config: config, mnemonic: nil, passphrase: nil, seed: seed)
        } catch {
            return nil
        }
    }

    private static func databaseIsBackgroundSafe(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        let locksWhileLocked: [FileProtectionType] = [.complete, .completeUnlessOpen]
        for file in files {
            if let prot = (try? fm.attributesOfItem(atPath: file.path))?[.protectionKey] as? FileProtectionType,
               locksWhileLocked.contains(prot) {
                return false
            }
        }
        return true
    }

    private static func bytes(fromHex s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    private static func isTransponderPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        if isBreezPush(userInfo) { return false }

        let source = (userInfo["source"] as? String)?.lowercased()
        if source == "transponder" || source == "marmot" { return true }

        if userInfo["mip05"] != nil
            || userInfo["transponder"] != nil
            || userInfo["wn_nse_prototype"] != nil {
            return true
        }

        if let kind = userInfo["kind"] as? Int, kind == 446 { return true }
        if let kind = userInfo["kind"] as? String, kind == "446" { return true }

        return false
    }

    private static func isBreezPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let source = (userInfo["source"] as? String)?.lowercased()
        return source == "breez" || userInfo["notification_type"] != nil
    }

    private static func configureTransponderNotification(_ content: UNMutableNotificationContent) {
        content.title = "New Sonar message"
        content.body = "Open Sonar to read it."
        content.sound = notificationSound
        content.categoryIdentifier = "sonar.message"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }
    }

    private static func mutableContent(for request: UNNotificationRequest) -> UNMutableNotificationContent {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        content.userInfo = request.content.userInfo
        return content
    }

    private static func transponderNotificationsEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return true }
        return defaults.object(forKey: notificationsEnabledKey) as? Bool ?? true
    }

    private static func notificationPrefs() -> NSENotificationPrefs {
        let defaults = UserDefaults(suiteName: appGroupId)
        return NSENotificationPrefs(
            showNames: defaults?.object(forKey: showNamesKey) as? Bool ?? true,
            showPreview: defaults?.object(forKey: showPreviewKey) as? Bool ?? false
        )
    }

    private static func suppressTransponderNotification(_ content: UNMutableNotificationContent) {
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.sound = nil
        content.badge = nil
        content.categoryIdentifier = ""
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
        }
    }
}

private struct NSENotificationPrefs {
    var showNames: Bool
    var showPreview: Bool
}

private enum NSEMarmotError: Error {
    case missingCredentials
    case appGroupUnavailable
    case sharedDatabaseMissing
    case databaseLocked
    /// Main app holds `MarmotStoreLock` — skip hydrate (fail closed).
    case storeBusy
}

#if DEBUG
final class NSEBreezLogger: BreezSDKLiquid.Logger {
    private static let log = OSLog(subsystem: "sh.hedwig.sonar", category: "NSE-Breez")
    func log(l: LogEntry) {
        let lvl = l.level.uppercased()
        let lower = l.line.lowercased()
        let interesting = lvl == "ERROR" || lvl == "WARN"
            || ["invoice", "swap", "connect", "bolt12", "payment", "fetch", "magic"]
                .contains { lower.contains($0) }
        guard interesting else { return }
        os_log("BREEZ[%{public}@] %{public}@", log: Self.log, type: .info, lvl, l.line)
    }
}
#endif
