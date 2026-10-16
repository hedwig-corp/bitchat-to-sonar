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
    /// Every distinct conversation a suppressed multi-group drain covered —
    /// the host's banner cleanup matches against this list too, so muting
    /// group A must not leave group B's blank placeholder stuck.
    private static let conversationIdsKey = "sonarConversationIds"
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
    /// Both sounds must be members of THIS extension target, not just the app:
    /// the appex has no synchronized-folder membership, so a file living under
    /// ios/bitchat/ never reaches it without an explicit pbxproj Resources
    /// entry. Shipping a name the appex does not contain degrades the killed-app
    /// banner to the default sound, silently. See docs/SONAR-TRILL.md.
    private static let trillNotificationSound = UNNotificationSound(
        named: UNNotificationSoundName(rawValue: "sonar_trill.wav")
    )

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var hydrateTask: Task<Void, Never>?
    private let wakeNodeLock = NSLock()
    private var marmotWakeNode: SonarNode?
    /// Held for the lifetime of `marmotWakeNode` so we never unlock before the
    /// SQLCipher handle is dropped (goose M1).
    private var marmotWakeStoreLock: MarmotStoreLock?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if Self.isTransponderPush(request.content.userInfo) {
            os_log("NSE: handling Transponder Marmot push",
                   log: Self.log, type: .info)
            Self.recordDiagnostic("didReceive:transponder")
            self.contentHandler = contentHandler
            let content = Self.mutableContent(for: request)
            bestAttemptContent = content
            guard Self.transponderNotificationsEnabled() else {
                os_log("NSE: suppressing Transponder notification by user preference",
                       log: Self.log, type: .info)
                Self.recordDiagnostic("suppressed:notificationsDisabled")
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
        // Do NOT release the store lock / SonarNode here. Collect owns that
        // lifecycle and may still hold an open SQLCipher handle on a worker;
        // unlock-before-close races the host (goose M1).
        #if DEBUG
        Self.logResidentMemory("expire")
        #endif
        if let content = bestAttemptContent {
            // Do NOT wipe a title/body hydrate already wrote. The previous
            // path always re-applied the generic placeholder here, so a slow
            // sync that finished apply-then-lost-the-race-to-expire delivered
            // "New Sonar message" even when diagnostics said decorated.
            let stillPlaceholder = (
                content.userInfo[SonarNSEDecoratePolicy.nsePlaceholderUserInfoKey] as? Bool
            ) == true
            if SonarNSEDecoratePolicy.shouldReapplyPlaceholderOnExpire(
                isPlaceholder: stillPlaceholder
            ) {
                // Same as empty drain: no chat id on the wire, so a sounding
                // placeholder would ring muted chats (R-022).
                Self.configureTransponderNotification(content, silent: true)
                Self.recordDiagnostic("expire:stillPlaceholderSilent")
            } else {
                Self.recordDiagnostic(
                    SonarNSEDecoratePolicy.diagnosticExpireKeepingDecorated(
                        title: content.title,
                        body: content.body
                    )
                )
            }
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
        // Blocking UniFFI + flock retries on a detached worker so
        // Thread.sleep does not pin a cooperative pool thread. Collect
        // still owns node+lock release (expire must not unlock under an
        // open handle). Retry storeBusy — host closeNode / a prior NSE
        // often holds the flock longer than one acquire window.
        let hintGroupId = SonarNSEDecoratePolicy.hintGroupIdHex(
            from: content.userInfo
        )
        let maxAttempts = SonarNSEDecoratePolicy.storeBusyHydrateRetries
        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else {
                finish(with: content)
                return
            }
            do {
                typealias WakeDrain = (notifications: [DrainNotificationInfo], accountPubkeyHex: String?)
                let drain: WakeDrain = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> WakeDrain in
                    guard let self else { return (notifications: [], accountPubkeyHex: nil) }
                    return try self.collectMarmotNotificationsAfterWake(
                        hintGroupIdHex: hintGroupId,
                        hydrateAttempt: attempt
                    )
                }.value
                let notifications = drain.notifications
                let accountPubkeyHex = drain.accountPubkeyHex
                #if DEBUG
                Self.logResidentMemory("after-wake")
                #endif
                guard !Task.isCancelled else {
                    finish(with: content)
                    return
                }
                if notifications.isEmpty {
                    // Production Transponder APNS has no group id — only an NSE
                    // marker — so we cannot mute-gate this placeholder by chat.
                    // Clearing sound (policy: undecoratedPlaceholderAlert) stops
                    // muted chats from ringing when hydrate found nothing; the
                    // host may still replace the row after open (R-022).
                    Self.applyUndecoratedPlaceholderSilence(content)
                    os_log("NSE: Marmot wake drained 0 notifications — keeping silent generic banner",
                           log: Self.log, type: .info)
                    Self.recordDiagnostic("emptyDrain:keepingGenericSilent")
                    finish(with: content)
                    return
                }
                // Per-chat mute (App Group mirror of SonarChatMuteStore):
                // muted rows stay row-only — no banner, no sound — matching
                // the silence table in docs/SONAR-TRILL.md. Decode the mirror
                // once for the whole drain, not once per row.
                let mutes = SonarNSEDecoratePolicy.decodeMutes(
                    UserDefaults(suiteName: Self.appGroupId)?
                        .data(forKey: SonarNSEDecoratePolicy.mutesUserDefaultsKey)
                )
                let unmuted = notifications.filter {
                    !SonarNSEDecoratePolicy.isMuted(
                        groupIdHex: $0.groupIdHex,
                        senderNpub: $0.senderNpub,
                        groupName: $0.groupName,
                        mutes: mutes,
                        now: Date()
                    )
                }
                if unmuted.isEmpty {
                    os_log("NSE: all drained notifications muted — suppressing banner",
                           log: Self.log, type: .info)
                    Self.recordDiagnostic("suppressed:muted count=\(notifications.count)")
                    // An NSE cannot drop a notification, only blank it, so a
                    // contentless row still lands in Notification Center.
                    // Stamp the conversation ids the host's mute branches pass
                    // to removeDeliveredNSEOwnedBanners — a suppressed
                    // placeholder never ran apply(), so without this it matches
                    // nothing and the blank row sticks until the user swipes it.
                    // The primary stamp is the TIP (newest — the row whose push
                    // produced this banner); one wake can drain muted rows from
                    // several groups, so every distinct id rides along too.
                    var mutedInfo = content.userInfo
                    if let gid = notifications.last?.groupIdHex, !gid.isEmpty {
                        mutedInfo[Self.conversationIdKey] =
                            Self.marmotConversationPrefix + gid
                    }
                    let allIds = Array(Set(
                        notifications.map(\.groupIdHex).filter { !$0.isEmpty }
                    )).map { Self.marmotConversationPrefix + $0 }
                    if !allIds.isEmpty {
                        mutedInfo[Self.conversationIdsKey] = allIds
                    }
                    content.userInfo = mutedInfo
                    Self.suppressTransponderNotification(content)
                    finish(with: content)
                    return
                }
                let prefs = Self.notificationPrefs()
                // Drain is oldest-first (sync queue + live append). Banner the tip.
                let ordered = Array(unmuted.reversed())
                let primary = ordered[0]
                Self.apply(
                    notification: primary,
                    to: content,
                    prefs: prefs,
                    accountPubkeyHex: accountPubkeyHex
                )
                let extras = Array(ordered.dropFirst().prefix(Self.maxAdditionalPresentations))
                for extra in extras {
                    Self.postAdditionalLocalNotification(
                        extra,
                        prefs: prefs,
                        accountPubkeyHex: accountPubkeyHex
                    )
                }
                os_log("NSE: Marmot wake decorated primary + %d additional",
                       log: Self.log, type: .info, extras.count)
                Self.recordDiagnostic(
                    SonarNSEDecoratePolicy.diagnosticDecorated(
                        showNames: prefs.showNames,
                        showPreview: prefs.showPreview,
                        extras: extras.count,
                        title: content.title,
                        body: content.body
                    )
                )
                finish(with: content)
                return
            } catch {
                let storeBusy: Bool = {
                    if let nse = error as? NSEMarmotError, case .storeBusy = nse { return true }
                    return false
                }()
                if storeBusy,
                   SonarNSEDecoratePolicy.shouldRetryHydrateAfterStoreBusy(
                    attempt: attempt,
                    maxAttempts: maxAttempts
                   ) {
                    Self.recordDiagnostic("storeBusy:hydrateRetry attempt=\(attempt)")
                    try? await Task.sleep(
                        nanoseconds: SonarNSEDecoratePolicy.storeBusyHydrateRetrySleepNs
                    )
                    continue
                }
                os_log("NSE: Marmot wake failed — %{private}@ — keeping generic banner",
                       log: Self.log, type: .error, String(describing: error))
                // Opaque tag only — never persist error strings (may embed SQL /
                // content). Prefer a prior precise stamp from credential/lock paths.
                if Self.lastDiagnostic().isEmpty {
                    Self.recordDiagnostic("failed:\(Self.opaqueErrorTag(error))")
                } else {
                    Self.recordDiagnostic("catch:\(Self.opaqueErrorTag(error))")
                }
                finish(with: content)
                return
            }
        }
        Self.recordDiagnostic("storeBusy:hydrateRetriesExhausted")
        finish(with: content)
    }

    /// One account the wake may belong to. Keychain names carry the
    /// `identity_` prefix `KeychainManager` adds in the app.
    private struct WakeAccount {
        let pubkeyHex: String
        let dbPath: String
        let nsecKeychainKey: String
        let dbKeychainKey: String
        let isActive: Bool
    }

    /// Budget for every account after the active one. The push carries no
    /// account id, so the active account gets the full White Noise window and
    /// the others a short peek each, bounded by `maxWakeAccounts`.
    private static let inactiveAccountWakeWaitMs: UInt64 = 3_000
    private static let maxWakeAccounts = 5
    /// Stop opening further accounts once this much of the ~30 s NSE budget
    /// is spent; decorate + finish still need time.
    private static let wakeAccountsDeadlineSecs: TimeInterval = 18

    /// Accounts to try, active first then most recently active. Without a
    /// registry (single-account install) or with one that cannot be read,
    /// this is the legacy store under the legacy keychain names — exactly
    /// what every earlier build opened. Never mints anything.
    private static func wakeAccountsInOrder(dataDir: URL) -> [WakeAccount] {
        let legacy = WakeAccount(
            pubkeyHex: "",
            dbPath: dataDir.appendingPathComponent("marmot.sqlite").path,
            nsecKeychainKey: nsecKeychainKey,
            dbKeychainKey: dbKeychainKey,
            isActive: true
        )
        let info: AccountRegistryInfo
        do {
            info = try accountRegistryLoad(dataDir: dataDir.path)
        } catch {
            // A registry that exists but cannot be read: the app runs the
            // legacy single-account path for this launch and so do we. Say so.
            recordDiagnostic("registryUnreadable")
            return [legacy]
        }
        guard !info.accounts.isEmpty else { return [legacy] }
        let sorted = info.accounts.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.lastActiveAt > b.lastActiveAt
        }
        return sorted.prefix(maxWakeAccounts).map { a in
            WakeAccount(
                pubkeyHex: a.pubkeyHex,
                dbPath: a.dbPath,
                nsecKeychainKey: "identity_" + accountSecretKeyName(base: "marmot-nsec", secretTag: a.secretTag),
                dbKeychainKey: "identity_" + accountSecretKeyName(base: "marmot-db-key", secretTag: a.secretTag),
                isActive: a.isActive
            )
        }
    }

    /// Blocking UniFFI work — always call off the main actor.
    /// Main app owns App Group migration; NSE never creates an empty SQLCipher DB.
    /// Skips when the main app holds `MarmotStoreLock` (no concurrent writers).
    ///
    /// Multi-account: one store lock for the whole pass, one open store at a
    /// time. The active account is drained first with the full window; when
    /// that yields nothing, the other registered accounts get a short peek
    /// each. The first non-empty drain wins and its account is stamped on the
    /// banner so a tap switches before opening. If nothing drained anywhere,
    /// the active account's unread tip (captured while its store was open) is
    /// the fallback, as before.
    private func collectMarmotNotificationsAfterWake(
        hintGroupIdHex: String?,
        hydrateAttempt: Int = 1
    ) throws -> (notifications: [DrainNotificationInfo], accountPubkeyHex: String?) {
        let dataDir = try Self.marmotDataDirectory()
        let accounts = Self.wakeAccountsInOrder(dataDir: dataDir)
        // Background suspend releases the flock asynchronously (beginBackgroundTask
        // + closeNode). Retry briefly so a Transponder wake that races the
        // suspend path still hydrates instead of sticking on the generic banner.
        let storeLock = try Self.acquireStoreLockForWake(hydrateAttempt: hydrateAttempt)
        wakeNodeLock.lock()
        marmotWakeStoreLock = storeLock
        wakeNodeLock.unlock()
        // Always close node before unlocking — never unlock under an open handle.
        defer { releaseMarmotWakeNode() }

        let startedAt = Date()
        var activeFallback: [DrainNotificationInfo] = []
        var activePubkey: String?
        var lastError: Error?
        var opened = 0
        var collected = 0
        for (index, account) in accounts.enumerated() {
            if index > 0, Date().timeIntervalSince(startedAt) > Self.wakeAccountsDeadlineSecs {
                Self.recordDiagnostic("wakeAccounts:deadline opened=\(opened)")
                break
            }
            // `serviceExtensionTimeWillExpire` releases the flock from under
            // us; never open another store after that.
            wakeNodeLock.lock()
            let lockStillHeld = marmotWakeStoreLock != nil
            wakeNodeLock.unlock()
            if !lockStillHeld {
                Self.recordDiagnostic("wakeAccounts:lockReleased opened=\(opened)")
                break
            }
            let nsec = Self.readKeychainString(account: account.nsecKeychainKey)
            let dbKeyHex = Self.readKeychainString(account: account.dbKeychainKey)
            guard let nsec, let dbKeyHex, !nsec.isEmpty, dbKeyHex.count == 64 else {
                Self.recordDiagnostic(
                    "missingCredentials:nsec=\(nsec != nil):dbKey=\(dbKeyHex?.count ?? -1):active=\(account.isActive)"
                )
                lastError = NSEMarmotError.missingCredentials
                continue
            }
            let dbURL: URL
            do {
                dbURL = try Self.existingMarmotDatabaseURL(path: account.dbPath)
            } catch {
                lastError = error
                continue
            }
            // An interrupted Blossom restore left staging beside this store:
            // only the app's own connect reconciles it. Opening here would
            // pair the old file with the restored key.
            if accountRestoreStagingPresent(dbPath: dbURL.path) {
                Self.recordDiagnostic("wakeAccounts:restoreStaged active=\(account.isActive)")
                lastError = NSEMarmotError.storeBusy
                continue
            }
            let identity: SonarIdentity
            do {
                identity = try SonarIdentity.import(nsec: nsec)
            } catch {
                lastError = error
                continue
            }
            // Registry and keychain can drift (a restore that died before
            // repointing its row). Never sync one identity against another
            // account's store.
            if !account.pubkeyHex.isEmpty, identity.pubkeyHex() != account.pubkeyHex {
                Self.recordDiagnostic("wakeAccounts:keyMismatch active=\(account.isActive)")
                lastError = NSEMarmotError.missingCredentials
                continue
            }
            let node: SonarNode
            do {
                node = try SonarNode.connect(
                    identity: identity,
                    relayUrls: Self.defaultRelayUrls,
                    dbPath: dbURL.path,
                    dbKeyHex: dbKeyHex,
                    // No suspend latch: the NSE is not the app process, has no
                    // scene-phase suspend hook to fire one, and is torn down by its
                    // own `serviceExtensionTimeWillExpire` deadline instead.
                    suspendLatch: nil
                )
            } catch {
                lastError = error
                continue
            }
            opened += 1
            wakeNodeLock.lock()
            marmotWakeNode = node
            wakeNodeLock.unlock()
            let waitMs = account.isActive ? Self.marmotWakeWaitMs : Self.inactiveAccountWakeWaitMs
            let drained: [DrainNotificationInfo]
            do {
                drained = try node.collectNotificationsAfterWake(maxWaitMs: waitMs)
                collected += 1
            } catch {
                lastError = error
                dropWakeNode()
                continue
            }
            if !drained.isEmpty {
                if !account.isActive {
                    Self.recordDiagnostic("wakeAccounts:drainedInactive index=\(index)")
                }
                let enriched = Self.enrichEmptyContentPreviews(drained, node: node)
                dropWakeNode()
                return (enriched, account.pubkeyHex.isEmpty ? nil : account.pubkeyHex)
            }
            if account.isActive {
                // Mirror SonarPushProcessor unread-delta: drain can be empty when the
                // row was already local, the concurrent app wake consumed the pending
                // list first, or sync only advanced summaries. Prefer the newest
                // unread conversation so the banner still gets names/preview.
                // Cap at one — extras from unrelated stale unreads look like spam
                // banners and hide the tip that just arrived.
                let fromUnread = Self.drainNotificationsFromUnreadSummaries(
                    node,
                    hintGroupIdHex: hintGroupIdHex
                )
                if !fromUnread.isEmpty {
                    activeFallback = Self.enrichEmptyContentPreviews(fromUnread, node: node)
                    activePubkey = account.pubkeyHex.isEmpty ? nil : account.pubkeyHex
                }
            }
            dropWakeNode()
        }
        if !activeFallback.isEmpty {
            Self.recordDiagnostic(
                SonarNSEDecoratePolicy.diagnosticFallbackUnread(count: activeFallback.count)
            )
            return (activeFallback, activePubkey)
        }
        // A connect that never collected is a failure, not an empty drain.
        if collected == 0, let lastError { throw lastError }
        return ([], nil)
    }

    /// Drop the open SQLCipher handle but keep the flock for the next account.
    private func dropWakeNode() {
        wakeNodeLock.lock()
        marmotWakeNode = nil
        wakeNodeLock.unlock()
    }

    /// Build banner rows from local unread conversation summaries (newest tip only).
    private static func drainNotificationsFromUnreadSummaries(
        _ node: SonarNode,
        hintGroupIdHex: String?
    ) -> [DrainNotificationInfo] {
        let unread = node.conversationSummaries()
            .filter { $0.unreadCount > 0 && !$0.latestMine }
            .sorted { $0.latestAtSecs > $1.latestAtSecs }
        let allowedIds = SonarNSEDecoratePolicy.filterUnreadTips(
            groupIdHexes: unread.map(\.groupIdHex),
            hintGroupIdHex: hintGroupIdHex
        )
        let previewById = Dictionary(
            unread.map { ($0.groupIdHex, $0.latestContent) },
            uniquingKeysWith: { _, newer in newer }
        )
        let preferredIds = SonarNSEDecoratePolicy.preferTipsWithPreview(
            groupIdHexes: allowedIds,
            previewByGroupIdHex: previewById
        )
        let allowed = Set(preferredIds.map { $0.lowercased() })
        return Array(
            unread
                .filter { allowed.contains($0.groupIdHex.lowercased()) }
                .prefix(1)
                .map { summary in
                    DrainNotificationInfo(
                        messageIdHex: "",
                        senderNpub: summary.latestSenderNpub,
                        groupIdHex: summary.groupIdHex,
                        groupName: summary.name,
                        contentPreview: summary.latestContent
                    )
                }
        )
    }

    /// When wake drain returns a tip with an empty preview (common when the
    /// row was indexed before content landed), fill from the conversation
    /// summary for the same group so showPreview banners are not generic.
    private static func enrichEmptyContentPreviews(
        _ notifications: [DrainNotificationInfo],
        node: SonarNode
    ) -> [DrainNotificationInfo] {
        let summaries = node.conversationSummaries()
        return notifications.map { note in
            let trimmed = note.contentPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty else { return note }
            let group = note.groupIdHex.lowercased()
            guard let summary = summaries.first(where: {
                $0.groupIdHex.lowercased() == group
            }) else { return note }
            let fromSummary = summary.latestContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fromSummary.isEmpty else { return note }
            return DrainNotificationInfo(
                messageIdHex: note.messageIdHex,
                senderNpub: note.senderNpub.isEmpty ? summary.latestSenderNpub : note.senderNpub,
                groupIdHex: note.groupIdHex,
                groupName: note.groupName.isEmpty ? summary.name : note.groupName,
                contentPreview: fromSummary
            )
        }
    }

    private func releaseMarmotWakeNode() {
        wakeNodeLock.lock()
        // Drop the SQLCipher handle first, then the flock.
        marmotWakeNode = nil
        marmotWakeStoreLock?.release()
        marmotWakeStoreLock = nil
        wakeNodeLock.unlock()
    }

    /// ~8s of flock retries. Matches the common race where the host has
    /// started `closeNode` but has not released `marmot.store.lock` yet.
    /// Blocking sleep is OK — callers run this on a `Task.detached` worker.
    private static func acquireStoreLockForWake(hydrateAttempt: Int = 1) throws -> MarmotStoreLock {
        let attempts = SonarNSEDecoratePolicy.storeLockRetryAttempts(
            forHydrateAttempt: hydrateAttempt
        )
        let delaySecs = 0.1
        var last: MarmotStoreLock.TryAcquireResult = .unavailable
        for attempt in 1...attempts {
            let result = MarmotStoreLock.tryAcquireExclusiveResult()
            last = result
            if case .acquired(let lock) = result {
                if attempt > 1 {
                    recordDiagnostic("storeLock:acquiredAfterRetry attempt=\(attempt)")
                }
                return lock
            }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: delaySecs)
            }
        }
        switch last {
        case .busy:
            recordDiagnostic("storeBusy:retries=\(attempts)")
            throw NSEMarmotError.storeBusy
        case .unavailable:
            recordDiagnostic("storeLockUnavailable")
            throw NSEMarmotError.sharedDatabaseMissing
        case .system(let err):
            recordDiagnostic("storeLockSystem:errno=\(err)")
            throw NSEMarmotError.storeBusy
        case .acquired:
            // Unreachable — loop returns on acquire.
            throw NSEMarmotError.storeBusy
        }
    }

    /// Require an existing shared DB — never mkdir+connect into a missing path
    /// (that would mint an empty SQLCipher store and orphan Application Support history).
    /// The store root (`<App Group>/sonar-marmot`): the legacy store and the
    /// account registry live here, added accounts under `accounts/<hex>/`.
    private static func marmotDataDirectory() throws -> URL {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            Self.recordDiagnostic("appGroupUnavailable")
            throw NSEMarmotError.appGroupUnavailable
        }
        return group.appendingPathComponent("sonar-marmot", isDirectory: true)
    }

    private static func existingMarmotDatabaseURL(path: String) throws -> URL {
        let db = URL(fileURLWithPath: path)
        let dir = db.deletingLastPathComponent()
        // Refuse missing or empty placeholders — connect would mint a forked
        // SQLCipher store and orphan Application Support history.
        guard MarmotAppGroupStore.isAuthoritativeDatabaseFile(db) else {
            Self.recordDiagnostic("sharedDatabaseMissing")
            throw NSEMarmotError.sharedDatabaseMissing
        }
        guard databaseIsBackgroundSafe(dir) else {
            Self.recordDiagnostic("databaseLocked")
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
        prefs: NSENotificationPrefs,
        accountPubkeyHex: String? = nil
    ) {
        // App Group kind-0 mirror — never fetchProfile (relay) from the NSE.
        // Pass alias via cachedBestName so senderLabel does not truncate it.
        let rendered = SonarNSEDecoratePolicy.render(
            input: .init(
                senderRaw: notification.senderNpub,
                groupName: notification.groupName,
                contentPreview: notification.contentPreview,
                cachedBestName: SonarSharedProfileNames.bestName(
                    for: notification.senderNpub
                )
            ),
            prefs: .init(showNames: prefs.showNames, showPreview: prefs.showPreview)
        )
        content.title = rendered.title
        content.body = rendered.body
        content.sound = rendered.isTrill ? trillNotificationSound : notificationSound
        content.categoryIdentifier = "sonar.message"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .active
        }
        var userInfo = content.userInfo
        // Decorated copy is no longer a privacy placeholder — clear that marker
        // and stamp nseDecorated so the host can replace this banner with a
        // named local notification instead of stacking a duplicate.
        userInfo.removeValue(forKey: SonarNSEDecoratePolicy.nsePlaceholderUserInfoKey)
        userInfo[SonarNSEDecoratePolicy.nseDecoratedUserInfoKey] = true
        if !notification.groupIdHex.isEmpty {
            userInfo[conversationIdKey] = marmotConversationPrefix + notification.groupIdHex
        }
        if !notification.messageIdHex.isEmpty {
            userInfo["sonar.messageId"] = notification.messageIdHex
        }
        // Which registered account this row came from, so a tap on another
        // account's banner switches before opening (`SonarNotificationKeys
        // .accountPubkey` in the app). Absent for the legacy single account.
        if let accountPubkeyHex, !accountPubkeyHex.isEmpty {
            userInfo["sonarAccountPubkey"] = accountPubkeyHex
        }
        content.userInfo = userInfo
    }

    private static func postAdditionalLocalNotification(
        _ notification: DrainNotificationInfo,
        prefs: NSENotificationPrefs,
        accountPubkeyHex: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        apply(notification: notification, to: content, prefs: prefs, accountPubkeyHex: accountPubkeyHex)
        // Prefer message id so UN replace + host R-004 dedup share one key.
        let idSuffix = notification.messageIdHex.isEmpty
            ? UUID().uuidString
            : notification.messageIdHex
        let id = "sonar-nse-\(idSuffix)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func finish(with content: UNNotificationContent) {
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        hydrateTask = nil
        if handler == nil {
            Self.recordDiagnostic(
                "finishDropped titleLen=\(content.title.count) (handler already consumed)"
            )
        }
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
        // Shared keychain group is team-prefixed `*.sh.hedwig.sonar` (see
        // entitlements). Main-app default access group matches that family id;
        // the NSE default is `*.NotificationService`, so we must query the
        // shared group explicitly. Never mint a replacement identity here.
        for accessGroup in sharedKeychainAccessGroupCandidates() {
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
        return nil
    }

    /// Team-prefixed shared groups (Debug + Release teams) plus legacy App Group
    /// and nil. Order: most-likely shared entitlement first.
    private static func sharedKeychainAccessGroupCandidates() -> [String?] {
        [
            "ZQB239SHCM.sh.hedwig.sonar", // Debug / Local.xcconfig team
            "L3N5LHJD5Y.sh.hedwig.sonar", // Release.xcconfig team
            appGroupId,                   // legacy attempt (pre-entitlement fix)
            nil,
        ]
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

    private static func configureTransponderNotification(
        _ content: UNMutableNotificationContent,
        silent: Bool = false
    ) {
        // Placeholder until hydrate decorates (or the app replaces this banner).
        // Mark with sonar.nsePlaceholder so SonarPushProcessor can remove THIS
        // banner by identity — never by matching title/body (those strings are
        // also the router's privacy fallback when Show names + preview are off).
        let showNames = notificationPrefs().showNames
        content.title = showNames ? "New Sonar message" : "Sonar"
        content.body = "Open Sonar to read it."
        content.categoryIdentifier = "sonar.message"
        var info = content.userInfo
        info[SonarNSEDecoratePolicy.nsePlaceholderUserInfoKey] = true
        info.removeValue(forKey: SonarNSEDecoratePolicy.nseDecoratedUserInfoKey)
        content.userInfo = info
        if silent {
            applyUndecoratedPlaceholderSilence(content)
        } else {
            content.sound = notificationSound
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .active
            }
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

    /// Durable breadcrumb for device debugging when unified logs are unavailable.
    /// Main app / `devicectl` can read `sonar.nse.lastDiagnostic` from the App Group.
    private static let diagnosticKey = "sonar.nse.lastDiagnostic"

    private static func recordDiagnostic(_ value: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(value)"
        defaults.set(stamped, forKey: diagnosticKey)
    }

    private static func lastDiagnostic() -> String {
        UserDefaults(suiteName: appGroupId)?.string(forKey: diagnosticKey) ?? ""
    }

    /// Opaque App Group diagnostic tag — never stringify full errors (may embed
    /// SQL / message content). Prefer typed NSEMarmotError cases.
    private static func opaqueErrorTag(_ error: Error) -> String {
        if let nse = error as? NSEMarmotError {
            switch nse {
            case .missingCredentials: return "missingCredentials"
            case .appGroupUnavailable: return "appGroupUnavailable"
            case .sharedDatabaseMissing: return "sharedDatabaseMissing"
            case .databaseLocked: return "databaseLocked"
            case .storeBusy: return "storeBusy"
            }
        }
        let typeName = String(describing: type(of: error))
        return "other:\(typeName)"
    }

    /// Strip sound from a still-generic placeholder. Call sites: empty drain
    /// and expire-before-decorate. See `undecoratedPlaceholderAlert`.
    private static func applyUndecoratedPlaceholderSilence(
        _ content: UNMutableNotificationContent
    ) {
        let alert = SonarNSEDecoratePolicy.undecoratedPlaceholderAlert()
        if !alert.attachesSound {
            content.sound = nil
        }
        if alert.passiveInterruption, #available(iOS 15.0, *) {
            content.interruptionLevel = .passive
        }
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
    /// Main app still holds `MarmotStoreLock` (foreground / not yet suspended)
    /// — skip hydrate (fail closed). After background the app releases the lock.
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
