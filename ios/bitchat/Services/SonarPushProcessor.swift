//
// SonarPushProcessor.swift
// bitchat
//
// Processes incoming silent push notifications from both servers:
//   - Transponder (Marmot): syncs relay, classifies messages, fires local notifs
//   - Breez NDS: wakes the wallet SDK to complete BOLT12 receives (silent)
//
// This runs from the AppDelegate's didReceiveRemoteNotification handler
// inside the 30-second background execution window iOS provides. The NSE
// may already have posted a placeholder or titled (`sonar.nseDecorated`)
// banner for killed-app wakes; this path removes those NSE-owned tips by
// message/conversation id and posts prefs-aware named copy when newly
// drained (or newly changed unread) local state is ready.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import UIKit
import UserNotifications
import os
import SonarCore

private struct SonarPushTimeoutError: Error {}

/// Thread-safe completion latch for `closeStoreWithDeadline`.
private final class SonarWakeCloseLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func complete() {
        lock.lock()
        done = true
        lock.unlock()
    }
    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

enum SonarPushProcessor {

    /// userInfo key set by the NSE on Transponder placeholders. Cleanup must
    /// match this identity — never title/body (those strings are also the
    /// router's privacy fallback when Show names + Message preview are off).
    static let nsePlaceholderUserInfoKey = SonarNSEDecoratePolicy.nsePlaceholderUserInfoKey
    static let nseDecoratedUserInfoKey = SonarNSEDecoratePolicy.nseDecoratedUserInfoKey

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.hedwig.sonar",
        category: "SonarPushProcessor"
    )

    /// Single-flight Marmot wake. Concurrent Transponder pushes coalesce onto
    /// one owner task; `marmotWakeNeedsRerun` forces another refresh after any
    /// push observed while the owner is still finishing (name resolve / notify).
    @MainActor
    private static var marmotWakeInFlight: Task<UIBackgroundFetchResult, Never>?
    @MainActor
    private static var marmotWakeNeedsRerun = false

    /// Classify and process a remote notification payload.
    /// Returns true if the push was handled, false otherwise.
    @MainActor
    static func process(
        userInfo: [AnyHashable: Any],
        marmot: MarmotChatModel?,
        wallet: SonarWalletProviding?,
        fetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let source = userInfo["source"] as? String ?? ""

        if source == "breez" || userInfo["notification_type"] != nil {
            processBreezWakeup(wallet: wallet, completionHandler: fetchCompletionHandler)
        } else {
            processMarmotWakeup(marmot: marmot, completionHandler: fetchCompletionHandler)
        }
    }

    // MARK: - Marmot (transponder)

    @MainActor
    private static func processMarmotWakeup(
        marmot: MarmotChatModel?,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        log.info("Processing Marmot push wakeup")
        let prefs = SonarNotificationPreferenceStore.loadMerged()

        guard let marmot else {
            if prefs.enabled {
                log.warning("Marmot not available, showing fallback notification")
            } else {
                log.info("Marmot not available, notifications disabled")
            }
            showFallbackNotification(prefs: prefs)
            completionHandler(.newData)
            return
        }

        if let existing = marmotWakeInFlight {
            // Coalesce duplicate work, but ensure at least one refresh runs
            // after this push — the in-flight wake may already be past drain
            // (e.g. resolving sender names) and would otherwise miss the row.
            log.info("Marmot push wake already in flight — coalescing with trailing refresh")
            marmotWakeNeedsRerun = true
            Task {
                let result = await existing.value
                completionHandler(result)
            }
            return
        }

        let task = Task { @MainActor () -> UIBackgroundFetchResult in
            defer {
                marmotWakeInFlight = nil
                marmotWakeNeedsRerun = false
            }
            // Own banners before any suspension so the live sink cannot emit
            // during the NSE snapshot await (or later wake work).
            // One ownership span for the whole single-flight + trailing refresh
            // loop — per-iteration begin/end cleared notified IDs and double-bannered.
            marmot.beginPushWakeNotificationOwnership()
            defer { marmot.endPushWakeNotificationOwnership() }

            // Snapshot placeholders present at wake start. Only those may be
            // removed when this wake posts titled copy — NSEs delivered for
            // other chats during the wake must stay until their own wake runs.
            let nsePlaceholderSnapshot = await deliveredNSEPlaceholderIds()

            var overall: UIBackgroundFetchResult = .noData
            var clearNSEPlaceholders = false
            // Outer loop: a push that arrives WHILE the store is being closed
            // sets marmotWakeNeedsRerun after the inner drain loop exited —
            // re-enter and drain it (reopening the node on demand) instead of
            // dropping it until the next wake. Reruns are bounded to the ~30s
            // iOS background window: only re-enter with enough headroom and
            // shrink the sync timeout (plus skip the cold-launch NSE yield) to
            // what remains, so the wake completes before iOS expires it.
            let wakeStart = Date()
            var syncTimeout = TransportConfig.marmotPushSyncTimeoutSeconds
            var skipNSEYield = false
            var keepDraining = true
            while keepDraining {
                repeat {
                    marmotWakeNeedsRerun = false
                    let outcome: MarmotWakeOutcome
                    if skipNSEYield {
                        // Rerun: bound the WHOLE reconnect+sync to the
                        // remaining window — ensureConnected() and refresh()'s
                        // ensureRelayConnected() can spend 10s+10s before the
                        // bounded sync even starts. On overrun, fail the rerun
                        // and fall through to the close; the push syncs on the
                        // next wake/foreground.
                        do {
                            outcome = try await withTimeout(seconds: syncTimeout) {
                                await runMarmotWakeup(
                                    marmot: marmot,
                                    prefs: prefs,
                                    syncTimeoutSeconds: syncTimeout,
                                    skipNSEYield: true
                                )
                            }
                        } catch {
                            log.warning("Coalesced Marmot rerun exceeded wake window: \(error)")
                            outcome = MarmotWakeOutcome(fetchResult: .failed, shouldClearNSEPlaceholders: false)
                        }
                    } else {
                        outcome = await runMarmotWakeup(
                            marmot: marmot,
                            prefs: prefs,
                            syncTimeoutSeconds: syncTimeout,
                            skipNSEYield: false
                        )
                    }
                    overall = mergeFetchResult(overall, outcome.fetchResult)
                    clearNSEPlaceholders = clearNSEPlaceholders || outcome.shouldClearNSEPlaceholders
                } while marmotWakeNeedsRerun

                if clearNSEPlaceholders {
                    removeDeliveredNSEPlaceholderBanners(onlyIdentifiers: nsePlaceholderSnapshot)
                    clearNSEPlaceholders = false
                }
                // A background wake opened the SQLCipher store (ensureConnected),
                // but scenePhase never transitions on a background launch, so no
                // suspend hook will close it. Release the node BEFORE the fetch
                // completion handler lets iOS suspend us — suspending while
                // holding the WAL/flock is the RunningBoard 0xdead10cc kill.
                // Gate on .background only: .active/.inactive means the user can
                // see the app and the foreground path owns the node.
                guard UIApplication.shared.applicationState == .background else { break }
                // Bound the close to what is left of the wake window. `closeNode()`
                // hops onto MarmotService's SERIAL work queue and waits for every
                // outstanding node lease, so a blocking relay FFI already parked
                // there (a descriptor fetch runs two 10s fetches) can hold it well
                // past the ~30s iOS gives us. Awaiting that bare means the fetch
                // completion handler never fires and we get suspended mid-close —
                // exactly the 0xdead10cc kill this exists to prevent.
                //
                // Never wait past the window: `closeStoreAfterBackgroundWake()`
                // holds a UIApplication background task across the close, so
                // abandoning the wait does NOT leave us suspending with the store
                // open — iOS keeps the process alive until the close lands. A
                // budget of 0 is therefore fine and correct when the sync already
                // burned the window; the close still completes, we just report
                // the fetch result on time instead of overrunning it.
                let closeBudget = max(
                    0,
                    Self.marmotWakeWindowSeconds - Date().timeIntervalSince(wakeStart)
                )
                if await closeStoreWithDeadline(marmot: marmot, seconds: closeBudget) == false {
                    log.warning("Marmot store close did not land in \(Int(closeBudget))s — continuing under a background task")
                }
                if UIApplication.shared.applicationState != .background {
                    // The user foregrounded WHILE closeNode() awaited — the
                    // scene-phase resume raced our close and could have failed
                    // to reconnect behind the nodeClosing fence. The foreground
                    // path owns the node now: settle any doomed in-flight
                    // refresh and re-kick the resume (no-op if the concurrent
                    // reconnect already landed). Foreground sync also covers
                    // any push that arrived during the close.
                    await marmot.reconnectIfForegroundAfterStoreClose()
                    keepDraining = false
                } else {
                    let remaining = Self.marmotWakeWindowSeconds - Date().timeIntervalSince(wakeStart)
                    keepDraining = marmotWakeNeedsRerun && remaining > Self.marmotWakeRerunMinSeconds
                    if keepDraining {
                        skipNSEYield = true
                        syncTimeout = min(
                            TransportConfig.marmotPushSyncTimeoutSeconds,
                            max(3, remaining - 2)
                        )
                    } else if marmotWakeNeedsRerun {
                        log.info("Skipping coalesced Marmot rerun — \(Int(remaining))s left in wake window")
                    }
                }
            }
            return overall
        }
        marmotWakeInFlight = task
        Task { @MainActor in
            let result = await task.value
            completionHandler(result)
        }
    }

    private struct MarmotWakeOutcome {
        let fetchResult: UIBackgroundFetchResult
        let shouldClearNSEPlaceholders: Bool
    }

    /// iOS gives a silent-push wake ~30s of background execution
    /// (TransportConfig documents the window); keep 2s of margin.
    private static let marmotWakeWindowSeconds: Double = 28
    /// Below this much remaining window a coalesced rerun cannot pay even a
    /// shrunk sync — skip it; the push syncs on the next wake/foreground.
    private static let marmotWakeRerunMinSeconds: Double = 8

    @MainActor
    private static func runMarmotWakeup(
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs,
        syncTimeoutSeconds: Double = TransportConfig.marmotPushSyncTimeoutSeconds,
        skipNSEYield: Bool = false
    ) async -> MarmotWakeOutcome {
        // Ownership is held by the outer single-flight loop so trailing
        // refreshes share one notified-ID set.

        // Hydrate the unread baseline from local storage BEFORE refresh.
        // Cold/background launches often have an empty in-memory summary
        // cache; capturing that empty map would treat every existing unread
        // chat as "new" after refresh and re-alert stale threads.
        // Only trust the baseline when the local read actually succeeded —
        // a failed load leaves the cache empty and must not count as hydrated.
        //
        // Yield briefly so a concurrent NSE hydrate can take the App Group
        // flock first. Production Transponder is alert+mutable-content (no
        // content-available), but some wakes still relaunch the host — without
        // this delay the host steals the lock and NSE stays on the generic
        // placeholder.
        let appState = UIApplication.shared.applicationState
        if !skipNSEYield && appState != .active {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        // #354: invalidate the stale relay latch first — a process-alive
        // background can leave relayConnected true after sockets die, so
        // ensureConnected() would no-op and refresh() would drain nothing.
        // Gate on `.background`, NOT on `.active`: `.inactive` (Control Center,
        // a system prompt) is still foreground with live sockets, and rebuilding
        // there would close a node polling/sends/media still hold.
        if RelayConnectionPolicy.shouldInvalidateOnPushWake(appVisible: appState != .background) {
            marmot.invalidateRelayConnection()
        }
        _ = await marmot.ensureConnected()
        let baselineHydrated = await marmot.loadLocalSummaries()
        let beforeUnread = unreadFingerprint(marmot: marmot)

        var drained: [DrainNotificationInfo] = []
        var synced = false
        do {
            drained = try await withTimeout(seconds: syncTimeoutSeconds) {
                await marmot.refresh()
            }
            synced = true
        } catch {
            log.warning("Marmot sync from push failed or timed out: \(error)")
            // Partial drain often already wrote the pushed row; reload local
            // summaries so a delta check can still render titled copy.
            _ = await marmot.loadLocalSummaries()
        }

        guard prefs.enabled else {
            log.info("Marmot wakeup done (synced=\(synced)), notifications disabled")
            return MarmotWakeOutcome(
                fetchResult: synced ? .newData : .failed,
                shouldClearNSEPlaceholders: false
            )
        }

        // Prefer drain metadata, then also run unread-delta so rows that land
        // via gap recovery after the returned drain list are not dropped.
        // Delta skips message tips already bannered from the drain list.
        var notified = 0
        if !drained.isEmpty {
            notified = await notifyDrained(drained, marmot: marmot, prefs: prefs)
        }
        // Reload summaries so delta sees gap-recovery advances during name resolve.
        _ = await marmot.loadLocalSummaries()
        notified += await notifyNewlyUnread(
            before: beforeUnread,
            baselineHydrated: baselineHydrated,
            marmot: marmot,
            prefs: prefs
        )

        switch (notified > 0, synced) {
        case (true, _):
            log.info("Marmot wakeup: notified for \(notified) conversation(s) (synced=\(synced))")
            // Wipe of NSE placeholders is deferred to the outer loop with a
            // start-of-wake snapshot so overlapping chats are not erased.
            return MarmotWakeOutcome(fetchResult: .newData, shouldClearNSEPlaceholders: true)
        case (false, true):
            log.info("Marmot sync completed from push, no new unread messages")
            return MarmotWakeOutcome(fetchResult: .newData, shouldClearNSEPlaceholders: false)
        case (false, false):
            // If NSE already delivered a titled banner, do not stack a second
            // generic fallback on top of it.
            if await hasDeliveredNSEDecoratedBanner() {
                log.warning("Marmot sync timed out; keeping NSE-decorated banner (no fallback)")
                return MarmotWakeOutcome(fetchResult: .failed, shouldClearNSEPlaceholders: false)
            }
            log.warning("Marmot sync timed out with nothing new unread, showing fallback")
            showFallbackNotification(prefs: prefs)
            // Avoid stacking NSE generic + local fallback generics (snapshot-scoped).
            return MarmotWakeOutcome(fetchResult: .failed, shouldClearNSEPlaceholders: true)
        }
    }

    /// Fingerprint unread conversations so a wake can detect *new* activity
    /// without re-alerting every leftover unread thread.
    @MainActor
    private static func unreadFingerprint(
        marmot: MarmotChatModel
    ) -> [String: SonarPushUnreadDelta.Fingerprint] {
        var out: [String: SonarPushUnreadDelta.Fingerprint] = [:]
        for summary in marmot.conversationSummariesByGroup.values where summary.unreadCount > 0 {
            out[summary.groupIdHex] = SonarPushUnreadDelta.Fingerprint(
                unread: summary.unreadCount,
                latestAt: summary.latestAt,
                content: summary.latestContent
            )
        }
        return out
    }

    @MainActor
    private static func notifyDrained(
        _ drained: [DrainNotificationInfo],
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> Int {
        var notified = 0
        for notif in drained {
            let kind: SonarLocalNotificationKind = {
                switch sonarNotificationClassifyContent(content: notif.contentPreview) {
                case .call: return .call
                case .payment: return .payment
                case .trill: return .trill
                default: return .message
                }
            }()
            if kind == .call { continue }
            // Per-chat mute. The drain payload carries no group id, so a
            // muted DM is matched by sender npub; muted GROUPS are only
            // caught by the summary path below (documented gap).
            if notif.groupName.isEmpty, !notif.senderNpub.isEmpty,
               SonarChatMuteStore.shared.isMuted(notif.senderNpub) {
                continue
            }
            // Receiver trill throttle: one alert per chat per window; excess
            // trills stay row-only (no silent banner — matches Android).
            var sound: SonarNotificationSound = .standard
            if kind == .trill {
                let throttleKey = notif.groupName.isEmpty ? notif.senderNpub : notif.groupName
                guard SonarTrillThrottle.shared.admit(chatKey: throttleKey) else {
                    // Throttled trills stay row-only, but the NSE banner for this
                    // row must not linger — it predates host routing.
                    await removeDeliveredNSEOwnedBanners(
                        messageIdHex: notif.messageIdHex.isEmpty ? nil : notif.messageIdHex,
                        conversationId: notif.groupIdHex.isEmpty ? nil : "marmot:" + notif.groupIdHex
                    )
                    continue
                }
                sound = .trill
            }

            let senderName: String?
            if prefs.showNames, !notif.senderNpub.isEmpty {
                senderName = await marmot.resolveSenderName(npub: notif.senderNpub)
            } else {
                senderName = nil
            }
            let groupName = notif.groupName.isEmpty ? nil : notif.groupName
            let conversationTitle = groupName ?? senderName
            // R-004: prefer message id; fall back to content-stable key only when
            // core omitted id (should not happen for real drains).
            let idKey = notif.messageIdHex.isEmpty
                ? [
                    notif.senderNpub,
                    notif.groupName,
                    notif.contentPreview,
                ].joined(separator: "|")
                : notif.messageIdHex
            let conversationId = notif.groupIdHex.isEmpty
                ? nil
                : "marmot:" + notif.groupIdHex
            var userInfo: [String: Any] = [SonarNotificationKeys.marmotWake: true]
            if let conversationId {
                userInfo[SonarNotificationKeys.conversationId] = conversationId
            }
            if !notif.messageIdHex.isEmpty {
                userInfo["sonar.messageId"] = notif.messageIdHex
            }

            guard let routed = SonarLocalNotificationRouter.make(
                idKey: idKey.isEmpty ? UUID().uuidString : idKey,
                kind: kind,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: notif.contentPreview.isEmpty ? nil : notif.contentPreview,
                prefs: prefs,
                userInfo: userInfo
            ) else { continue }

            // Replace the NSE APNs / extra-local banner for this tip so the
            // lock screen does not stack "New message" + named host copy.
            await removeDeliveredNSEOwnedBanners(
                messageIdHex: notif.messageIdHex.isEmpty ? nil : notif.messageIdHex,
                conversationId: conversationId
            )
            NotificationService.shared.sendLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier,
                userInfo: routed.userInfo,
                sound: sound
            )
            // Correlate to local message IDs (handles truncated drain previews).
            marmot.notePushWakeNotified(drain: notif)
            notified += 1
        }
        return notified
    }

    /// Notify only unread conversations that advanced during this wake.
    @MainActor
    private static func notifyNewlyUnread(
        before: [String: SonarPushUnreadDelta.Fingerprint],
        baselineHydrated: Bool,
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs
    ) async -> Int {
        let after = marmot.conversationSummariesByGroup.values.filter { summary in
            SonarPushUnreadDelta.isNewlyAdvanced(
                groupId: summary.groupIdHex,
                after: SonarPushUnreadDelta.Fingerprint(
                    unread: summary.unreadCount,
                    latestAt: summary.latestAt,
                    content: summary.latestContent
                ),
                before: before,
                baselineHydrated: baselineHydrated
            )
        }
        if after.isEmpty { return 0 }

        var notified = 0
        for summary in after {
            // Skip only when drain already bannered *this* tip message.
            // Group-level exclude dropped a second in-group advance that landed
            // via gap recovery after the drain list was returned.
            if marmot.pushWakeAlreadyNotifiedLatest(
                groupIdHex: summary.groupIdHex,
                content: summary.latestContent
            ) {
                continue
            }

            let kind: SonarLocalNotificationKind = {
                switch sonarNotificationClassifyContent(content: summary.latestContent) {
                case .call: return .call
                case .payment: return .payment
                case .trill: return .trill
                default: return .message
                }
            }()
            if kind == .call { continue }
            // Per-chat mute: unread still accrues, no banner.
            if SonarChatMuteStore.shared.isMuted(summary.groupIdHex) { continue }
            // Receiver trill throttle: excess trills stay row-only.
            var sound: SonarNotificationSound = .standard
            if kind == .trill {
                guard SonarTrillThrottle.shared.admit(chatKey: summary.groupIdHex) else {
                    await removeDeliveredNSEOwnedBanners(
                        messageIdHex: nil,
                        conversationId: summary.groupIdHex.isEmpty ? nil : "marmot:" + summary.groupIdHex
                    )
                    continue
                }
                sound = .trill
            }

            let senderName: String?
            if prefs.showNames, !summary.latestSenderNpub.isEmpty {
                senderName = await marmot.resolveSenderName(npub: summary.latestSenderNpub)
            } else {
                senderName = nil
            }
            let conversationTitle = summary.name.isEmpty ? senderName : summary.name
            let groupName: String? = {
                guard let senderName, !summary.name.isEmpty, summary.name != senderName else {
                    return nil
                }
                return summary.name
            }()

            let conversationId = summary.groupIdHex.isEmpty
                ? nil
                : "marmot:" + summary.groupIdHex
            var userInfo: [String: Any] = [SonarNotificationKeys.marmotWake: true]
            if let conversationId {
                userInfo[SonarNotificationKeys.conversationId] = conversationId
            }

            guard let routed = SonarLocalNotificationRouter.make(
                idKey: summary.groupIdHex,
                kind: kind,
                conversationTitle: conversationTitle,
                senderName: senderName,
                groupName: groupName,
                preview: summary.latestContent.isEmpty ? nil : summary.latestContent,
                prefs: prefs,
                unreadCount: summary.unreadCount,
                userInfo: userInfo
            ) else { continue }

            await removeDeliveredNSEOwnedBanners(
                messageIdHex: nil,
                conversationId: conversationId
            )
            NotificationService.shared.sendLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier,
                userInfo: routed.userInfo,
                sound: sound
            )
            marmot.notePushWakeNotified(groupIdHex: summary.groupIdHex, content: summary.latestContent)
            notified += 1
        }
        return notified
    }

    // MARK: - Breez (NDS)

    @MainActor
    private static func processBreezWakeup(
        wallet: SonarWalletProviding?,
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        log.info("Processing Breez push wakeup (silent)")

        guard let wallet else {
            log.info("Wallet not available for Breez wakeup")
            completionHandler(.noData)
            return
        }

        guard case .ready = wallet.state else {
            log.info("Wallet not ready for Breez wakeup")
            completionHandler(.noData)
            return
        }

        log.info("Breez wakeup: wallet already running, SDK will process event")
        completionHandler(.newData)
    }

    // MARK: - Helpers

    private static func mergeFetchResult(
        _ a: UIBackgroundFetchResult,
        _ b: UIBackgroundFetchResult
    ) -> UIBackgroundFetchResult {
        // Prefer evidence of work: newData > failed > noData.
        switch (a, b) {
        case (.newData, _), (_, .newData): return .newData
        case (.failed, _), (_, .failed): return .failed
        default: return .noData
        }
    }

    private static func showFallbackNotification(prefs: SonarLocalNotificationPrefs) {
        var mutedPreview = prefs
        mutedPreview.showPreview = false
        guard let routed = SonarLocalNotificationRouter.make(
            idKey: UUID().uuidString,
            kind: .message,
            conversationTitle: nil,
            preview: nil,
            prefs: mutedPreview,
            userInfo: [SonarNotificationKeys.marmotWake: true]
        ) else { return }
        NotificationService.shared.sendLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: routed.identifier,
            userInfo: routed.userInfo
        )
    }

    /// Drop NSE Transponder placeholders once we have real local copy.
    /// Matches `sonar.nsePlaceholder` only — never user-visible title/body.
    static func isNSEPlaceholder(_ content: UNNotificationContent) -> Bool {
        boolUserInfo(content, key: nsePlaceholderUserInfoKey)
    }

    /// NSE finished a titled hydrate — host may replace this banner.
    static func isNSEDecorated(_ content: UNNotificationContent) -> Bool {
        boolUserInfo(content, key: nseDecoratedUserInfoKey)
    }

    /// Placeholder or decorated — anything the NSE owns on the lock screen.
    static func isNSEOwned(_ content: UNNotificationContent) -> Bool {
        isNSEPlaceholder(content) || isNSEDecorated(content)
    }

    private static func boolUserInfo(_ content: UNNotificationContent, key: String) -> Bool {
        if let flag = content.userInfo[key] as? Bool { return flag }
        if let flag = content.userInfo[key] as? NSNumber { return flag.boolValue }
        return false
    }

    /// Pure filter used by wipe + tests: keep only placeholder ids that were
    /// already delivered when this wake started (`allowed`).
    static func nsePlaceholderIdsToRemove(
        deliveredPlaceholderIds: Set<String>,
        allowedFromWakeStart: Set<String>
    ) -> [String] {
        deliveredPlaceholderIds.intersection(allowedFromWakeStart).sorted()
    }

    /// Pure filter: NSE-owned delivered ids that match tip message / conversation.
    static func nseOwnedIdsToRemove(
        delivered: [(id: String, messageId: String?, conversationId: String?)],
        messageIdHex: String?,
        conversationId: String?
    ) -> [String] {
        let mid = messageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cid = conversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return delivered.compactMap { row in
            if let mid, !mid.isEmpty, row.messageId == mid { return row.id }
            if let cid, !cid.isEmpty, row.conversationId == cid { return row.id }
            return nil
        }
    }

    private static func deliveredNSEPlaceholderIds() async -> Set<String> {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                let ids = Set(notes.compactMap { note -> String? in
                    guard isNSEPlaceholder(note.request.content) else { return nil }
                    return note.request.identifier
                })
                continuation.resume(returning: ids)
            }
        }
    }

    private static func hasDeliveredNSEDecoratedBanner() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                continuation.resume(returning: notes.contains { isNSEDecorated($0.request.content) })
            }
        }
    }

    private static func removeDeliveredNSEPlaceholderBanners(onlyIdentifiers: Set<String>) {
        // Empty snapshot ⇒ nothing was present at wake start; do not wipe
        // placeholders that arrived for other chats during this wake.
        guard !onlyIdentifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let delivered = Set(notes.compactMap { note -> String? in
                guard isNSEPlaceholder(note.request.content) else { return nil }
                return note.request.identifier
            })
            let ids = nsePlaceholderIdsToRemove(
                deliveredPlaceholderIds: delivered,
                allowedFromWakeStart: onlyIdentifiers
            )
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Remove NSE APNs / extra-local banners for the tip we are about to
    /// re-notify from the host (named, resolved), so they do not stack.
    private static func removeDeliveredNSEOwnedBanners(
        messageIdHex: String?,
        conversationId: String?
    ) async {
        guard (messageIdHex?.isEmpty == false) || (conversationId?.isEmpty == false) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { notes in
                let rows: [(id: String, messageId: String?, conversationId: String?)] = notes.compactMap { note in
                    let content = note.request.content
                    guard isNSEOwned(content) else { return nil }
                    let mid = content.userInfo["sonar.messageId"] as? String
                    let cid = content.userInfo[SonarNotificationKeys.conversationId] as? String
                    return (note.request.identifier, mid, cid)
                }
                let ids = nseOwnedIdsToRemove(
                    delivered: rows,
                    messageIdHex: messageIdHex,
                    conversationId: conversationId
                )
                if !ids.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: ids)
                }
                continuation.resume()
            }
        }
    }

    /// Wait up to `seconds` for the store close, then give up WITHOUT waiting for it.
    ///
    /// Deliberately not `withTimeout`: that is built on `withThrowingTaskGroup`, and
    /// a task group awaits its child tasks before returning or rethrowing. Cancellation
    /// is cooperative, and `closeNode()` parks in `withCheckedContinuation` behind a
    /// serial queue inside uncancellable Rust — so a group-based deadline expires and
    /// then blocks for the full close anyway. #446 made the *sync* deadline land by
    /// adding `Task.isCancelled` checks to the `ensureConnected()` /
    /// `ensureRelayConnected()` poll loops; the close has no such seam. Abandoning the
    /// wait is the only thing that actually bounds it.
    ///
    /// Returning early is safe because `closeStoreAfterBackgroundWake()` holds a
    /// `UIApplication` background task across the close, so iOS keeps the process
    /// alive until the store is actually shut instead of suspending us with it open.
    /// The flock is NOT dropped ahead of the node — see that method for why.
    ///
    /// Returns true when the close completed inside the budget.
    @MainActor
    private static func closeStoreWithDeadline(
        marmot: MarmotChatModel,
        seconds: TimeInterval
    ) async -> Bool {
        let latch = SonarWakeCloseLatch()
        Task.detached(priority: .userInitiated) {
            await marmot.closeStoreAfterBackgroundWake()
            latch.complete()
            // The caller may already have given up on the deadline and moved past
            // its own foreground recheck, which would then have run while the node
            // was still open (seeing it connected, doing nothing) — leaving the
            // foregrounded app disconnected once this close finally lands. Recheck
            // here, after the close is real. Idempotent: it gates on
            // `applicationState` and `isConnected()`.
            await marmot.reconnectIfForegroundAfterStoreClose()
        }
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if latch.isComplete { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return latch.isComplete
    }

    private static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SonarPushTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

#endif
