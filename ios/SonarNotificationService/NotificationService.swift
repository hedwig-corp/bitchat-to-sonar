//
// NotificationService.swift
// SonarNotificationService
//
// Breez Notification Plugin entry point — wakes the Breez SDK in this extension
// process (even when the Sonar app is backgrounded or force-quit) to answer
// offline BOLT12 invoice requests and swap updates. This is what lets a payer
// pay this device's BOLT12 offer while Sonar isn't running.
//
// The base class `SDKNotificationService` (from BreezSDKLiquid) does the work:
// it parses the push, connects the SDK with the ConnectRequest we return below,
// runs the matching task (e.g. InvoiceRequestTask), and posts a notification.
// On success the invoice-request task is silent — the user-facing notice arrives
// as the Sonar ⚡PAY message on the Transponder channel.
//
// Creds + working dir are shared by SonarWallet via the App Group; keep the keys
// and the working-dir layout in sync with SonarWalletKit/Sources/SonarWallet.swift.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BreezSDKLiquid
import UserNotifications
import os

class NotificationService: SDKNotificationService {

    private static let appGroupId = "group.sh.hedwig.sonar"
    private static let notificationsEnabledKey = "sonar.notifications.enabled"
    private static let log = OSLog(subsystem: "sh.hedwig.sonar", category: "NSE")

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if Self.isTransponderPush(request.content.userInfo) {
            os_log("NSE: handling Transponder Marmot push",
                   log: Self.log, type: .info)
            let content = Self.mutableContent(for: request)
            guard Self.transponderNotificationsEnabled() else {
                os_log("NSE: suppressing Transponder notification by user preference",
                       log: Self.log, type: .info)
                Self.suppressTransponderNotification(content)
                contentHandler(content)
                return
            }
            Self.configureTransponderNotification(content)
            contentHandler(content)
            return
        }

        #if DEBUG
        os_log("NSE: didReceive push, userInfo=%{public}@",
               log: Self.log, type: .info, String(describing: request.content.userInfo))
        setServiceLogger(logger: NSEBreezLogger())
        #endif
        super.didReceive(request, withContentHandler: contentHandler)
    }

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
        // Pin the Breez SQLite store to .completeUntilFirstUserAuthentication, NOT
        // .complete: the NSE connects the SDK while the device is locked, so a
        // .complete store would either SIGBUS on the mmap'd -shm page or get the
        // process killed with 0xdead10cc for holding a lock on an unavailable file.
        // Keep in sync with SonarWallet.applyDatabaseProtection (separate target —
        // can't share the helper). Heals existing files in place; sets the dir
        // default for files the SDK creates at connect.
        let dbProtection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? FileManager.default.setAttributes(dbProtection, ofItemAtPath: workingDir.path)
        for file in (try? FileManager.default.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.setAttributes(dbProtection, ofItemAtPath: file.path)
        }

        // The heal above is best-effort: on a locked device the `setAttributes`
        // calls silently no-op, so a store an older build wrote as `.complete` can
        // still be protected here. Connecting Breez against a `.complete` WAL store
        // while locked is exactly what SIGBUSes / 0xdead10ccs. Detect an unhealed
        // store and DEFER this push rather than crash — the next unlocked foreground
        // heals the files in the app, and later pushes connect cleanly. (Mirrors
        // MarmotService.databaseIsBackgroundSafe from #133.)
        guard Self.databaseIsBackgroundSafe(workingDir) else {
            os_log("NSE: Breez store still .complete (locked, pre-heal) — deferring connect to avoid SIGBUS/0xdead10cc",
                   log: Self.log, type: .error)
            return nil
        }

        do {
            var config = try defaultConfig(network: network, breezApiKey: apiKey)
            config.workingDir = workingDir.path
            // Keep the extension's work to just the invoice-request / swap-update
            // handling the push is for; skip the background realtime-sync service.
            config.syncServiceUrl = nil
            return ConnectRequest(config: config, mnemonic: nil, passphrase: nil, seed: seed)
        } catch {
            return nil
        }
    }

    /// Whether the Breez store is safe to open during locked background work — i.e.
    /// no file is still a lock-while-locked protection class. A `.complete` /
    /// `.completeUnlessOpen` WAL store opened while the device is locked SIGBUSes on
    /// the mmap'd `-shm` page (or 0xdead10ccs on a held lock), so when the in-place
    /// heal couldn't run (locked wake) we must defer rather than connect.
    ///
    /// - A fresh/empty dir is safe: the dir default we just set pins the class on
    ///   the files the SDK is about to create.
    /// - A dir we cannot even enumerate is unsafe — that only happens for a
    ///   `.complete` dir while locked on a real device — so defer.
    /// - The protection CLASS is file metadata and stays readable while locked, so a
    ///   pre-migration `.complete` store is still caught here. A nil/absent class
    ///   means no Data Protection is in force (Simulator) — safe.
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
        // Never trust provider payload copy for user-visible text. Transponder
        // pushes are plaintext-free wakeups; the app renders precise copy after open.
        content.title = "New Sonar message"
        content.body = "Open Sonar to read it."
        content.sound = .default
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
        guard let defaults = UserDefaults(suiteName: Self.appGroupId) else { return true }
        return defaults.object(forKey: notificationsEnabledKey) as? Bool ?? true
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

#if DEBUG
/// DEBUG-only: forwards the Breez SDK's internal logs (connect, invoice-request
/// handling) to os_log so the offline-receive flow is visible during testing.
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
