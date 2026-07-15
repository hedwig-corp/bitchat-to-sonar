//
// SonarPushProcessor.swift
// bitchat
//
// Processes incoming silent push notifications from both servers:
//   - Transponder (Marmot): syncs relay, classifies messages, fires local notifs
//   - Breez NDS: wakes the wallet SDK to complete BOLT12 receives (silent)
//
// This runs from the AppDelegate's didReceiveRemoteNotification handler
// inside the 30-second background execution window iOS provides. A future
// Notification Service Extension (issue #65) will add richer handling.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import Foundation
import UIKit
import BackgroundTasks
import os
import SonarCore

@MainActor
private final class SonarPushCompletionGate {
    private var finished = false
    private let completion: (UIBackgroundFetchResult) -> Void

    init(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        self.completion = completion
    }

    func finish(_ result: UIBackgroundFetchResult) {
        guard !finished else { return }
        finished = true
        completion(result)
    }

    var isFinished: Bool { finished }
}

@MainActor
private final class SonarBGCompletionGate {
    private var finished = false
    private let task: BGTask

    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
    }

    var isFinished: Bool { finished }
}

enum SonarPushCallAction: Equatable {
    case incomingOffer(callId: String)
    case cancel(callId: String)
    case acknowledge
    case message
}

enum SonarPushProcessor {

    private static let continuationTaskIdentifier = "sh.hedwig.sonar.notification-catch-up"
    private static let continuationStateKey = "sonar.notifications.catchup.state.v2"
    private static let maximumContinuationAttempts = 5
    @MainActor
    private static var activeSurface: (id: UUID, task: Task<Int, Never>)?

    struct ContinuationState: Codable, Equatable {
        var ownerId: String?
        var generation = 0
        var dirty = false
        var attempts = 0
        var surfacedGeneration = 0
        var fallbackGeneration = 0

        mutating func admit(ownerId: String) {
            precondition(!ownerId.isEmpty)
            if self.ownerId != ownerId {
                self = ContinuationState(ownerId: ownerId)
            }
            generation &+= 1
            dirty = true
            attempts = 0
        }

        mutating func markSurfaced(through value: Int) {
            surfacedGeneration = max(surfacedGeneration, value)
        }

        mutating func markFallback(through value: Int) {
            fallbackGeneration = max(fallbackGeneration, value)
        }

        func needsFallback(for value: Int) -> Bool {
            value > surfacedGeneration && value > fallbackGeneration
        }

        func belongs(to ownerId: String?) -> Bool {
            guard let ownerId, !ownerId.isEmpty else { return false }
            return self.ownerId == ownerId
        }

        mutating func clearUnlessOwned(by ownerId: String?) {
            if !belongs(to: ownerId) { self = ContinuationState() }
        }
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sh.hedwig.sonar",
        category: "SonarPushProcessor"
    )

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
        let prefs = notificationPrefs()
        let completion = SonarPushCompletionGate(completionHandler)

        guard let marmot else {
            log.warning("No Marmot account owner was injected; refusing unowned wake")
            invalidateBackgroundContinuation()
            completion.finish(.noData)
            return
        }

        Task {
            guard let ownerId = await marmot.notificationAccountOwner() else {
                log.warning("No stable Marmot account owner; refusing unowned wake")
                invalidateBackgroundContinuation()
                completion.finish(.noData)
                return
            }
            let deadline = Date().addingTimeInterval(
                TransportConfig.marmotPushEndToEndDeadlineSeconds
            )
            let continuationGeneration = claimBackgroundContinuation(ownerId: ownerId)
            Task { @MainActor in
                let nanos = UInt64(
                    TransportConfig.marmotPushEndToEndDeadlineSeconds * 1_000_000_000
                )
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled, !completion.isFinished else { return }
                rescheduleBackgroundContinuation(
                    ifGeneration: continuationGeneration,
                    ownerId: ownerId,
                    marmot: marmot
                )
                await showFallbackNotificationOnce(
                    marmot: marmot,
                    prefs: prefs,
                    generation: continuationGeneration,
                    ownerId: ownerId
                )
                completion.finish(.failed)
            }
            let recovery = await performMarmotRecovery(
                marmot: marmot,
                prefs: prefs,
                deadline: deadline,
                showFallback: true,
                continuationGeneration: continuationGeneration,
                ownerId: ownerId
            )
            if recovery.completed {
                clearBackgroundContinuation(
                    ifGeneration: continuationGeneration,
                    ownerId: ownerId
                )
            } else {
                rescheduleBackgroundContinuation(
                    ifGeneration: continuationGeneration,
                    ownerId: ownerId,
                    marmot: marmot
                )
            }
            completion.finish(recovery.hadData ? .newData : .noData)
        }
    }

    private struct MarmotRecoveryOutcome {
        let completed: Bool
        let hadData: Bool
    }

    @MainActor
    private static func performMarmotRecovery(
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs,
        deadline: Date,
        showFallback: Bool,
        continuationGeneration: Int,
        ownerId: String
    ) async -> MarmotRecoveryOutcome {
        guard await continuationIsCurrent(
            generation: continuationGeneration,
            ownerId: ownerId,
            marmot: marmot
        ) else {
            log.info("Notification continuation retired before sync after account changed")
            return MarmotRecoveryOutcome(completed: true, hadData: false)
        }
        guard let snapshot = await marmot.refreshForNotification(
            deadline: deadline,
            renderMarginSeconds: TransportConfig.marmotPushRenderMarginSeconds
        ) else {
            log.warning("Marmot notification recovery unavailable before native bounded sync")
            if showFallback {
                await showFallbackNotificationOnce(
                    marmot: marmot,
                    prefs: prefs,
                    generation: continuationGeneration,
                    ownerId: ownerId
                )
            }
            return MarmotRecoveryOutcome(completed: false, hadData: false)
        }
        let result = snapshot.result
        guard await marmot.notificationSessionGeneration() == snapshot.sessionGeneration else {
            log.info("Notification recovery retired after account generation changed")
            return MarmotRecoveryOutcome(completed: true, hadData: false)
        }
        log.info("Marmot notification sync completed=\(result.completed) timedOut=\(result.timedOut) truncated=\(result.truncated) processed=\(result.processedEvents) notifications=\(result.notifications.count) elapsedMs=\(result.elapsedMs)")
        let pendingBeforeSurface = await marmot.pendingNotifications()
        let surfacedCount = await surfacePendingNotifications(
            marmot: marmot,
            prefs: prefs,
            expectedSessionGeneration: snapshot.sessionGeneration
        )
        let pendingAfterSurface = await marmot.pendingNotifications()
        guard await marmot.notificationSessionGeneration() == snapshot.sessionGeneration else {
            log.info("Notification recovery retired after account generation changed during rendering")
            return MarmotRecoveryOutcome(completed: true, hadData: surfacedCount > 0)
        }
        let remainingIds = Set(pendingAfterSurface.map(\.messageId))
        let acknowledgedByAnotherWake = pendingBeforeSurface.contains {
            !remainingIds.contains($0.messageId)
        }
        let madePreciseProgress = surfacedCount > 0 || acknowledgedByAnotherWake
        if pendingAfterSurface.isEmpty && showFallback && !madePreciseProgress {
            await showFallbackNotificationOnce(
                marmot: marmot,
                prefs: prefs,
                generation: continuationGeneration,
                ownerId: ownerId
            )
        }
        if madePreciseProgress {
            markSurfaced(through: continuationGeneration, ownerId: ownerId)
            if let lease = await marmot.notificationRenderLease(
                expectedSessionGeneration: snapshot.sessionGeneration
            ) {
                _ = await NotificationService.shared.cancelLocalNotificationAccepted(
                    identifier: fallbackNotificationIdentifier,
                    renderLease: lease
                )
            }
        }
        return MarmotRecoveryOutcome(
            completed: result.completed && Date() < deadline,
            hadData: madePreciseProgress
        )
    }

    @MainActor
    static func surfacePendingNotifications(
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs? = nil,
        expectedSessionGeneration: UInt64? = nil
    ) async -> Int {
        // A waiter must take a fresh snapshot after the prior renderer. Sharing
        // its count could mark a newer wake as surfaced even when that wake's
        // message arrived behind the first snapshot.
        while let active = activeSurface {
            _ = await active.task.value
            if activeSurface?.id == active.id { activeSurface = nil }
        }
        let id = UUID()
        let resolvedPrefs = prefs ?? notificationPrefs()
        let task = Task { @MainActor in
            let surfaceGeneration: UInt64
            if let expectedSessionGeneration {
                surfaceGeneration = expectedSessionGeneration
            } else {
                surfaceGeneration = await marmot.notificationSessionGeneration()
            }
            guard await marmot.notificationSessionGeneration() == surfaceGeneration else {
                return 0
            }
            let pending = await marmot.pendingNotifications()
            guard await marmot.notificationSessionGeneration() == surfaceGeneration else {
                return 0
            }
            return await surface(
                pending,
                marmot: marmot,
                prefs: resolvedPrefs,
                expectedSessionGeneration: surfaceGeneration
            )
        }
        activeSurface = (id, task)
        let result = await task.value
        if activeSurface?.id == id { activeSurface = nil }
        return result
    }

    /// Foreground delivery is completed by the observable chat model rather
    /// than Notification Center. Call this only after the model has emitted its
    /// UI update; acknowledge only rows that are actually present locally.
    @MainActor
    static func acknowledgeForegroundNotifications(
        marmot: MarmotChatModel
    ) async -> Int {
        while let active = activeSurface {
            _ = await active.task.value
            if activeSurface?.id == active.id { activeSurface = nil }
        }
        let sessionGeneration = await marmot.notificationSessionGeneration()
        var renderedMessageIds = Set<String>()
        for messages in marmot.messagesByGroup.values {
            renderedMessageIds.formUnion(messages.map(\.id))
        }
        let acknowledged = await marmot.pendingNotifications()
            .map(\.messageId)
            .filter { renderedMessageIds.contains($0) }
        guard !acknowledged.isEmpty else { return 0 }
        let count = Int(await marmot.acknowledgeNotifications(
            messageIds: acknowledged,
            expectedSessionGeneration: sessionGeneration
        ))
        if count > 0,
           let ownerId = await marmot.notificationAccountOwner(),
           continuationState().belongs(to: ownerId) {
            markSurfaced(
                through: continuationState().generation,
                ownerId: ownerId
            )
        }
        return count
    }

    @MainActor
    private static func surface(
        _ pending: [DrainNotificationInfo],
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs,
        expectedSessionGeneration: UInt64
    ) async -> Int {
        let nowSecs = UInt64(max(0, Date().timeIntervalSince1970))
        let blockedNostr = SecureIdentityStateManager.persistedBlockedNostrPubkeys()
        var acknowledged: [String] = []
        for notification in pending {
            if await marmot.notificationSessionGeneration() != expectedSessionGeneration {
                break
            }
            if isSenderBlocked(notification.senderNpub, blockedNostr: blockedNostr) {
                acknowledged.append(notification.messageId)
                continue
            }
            if await render(
                notification,
                marmot: marmot,
                prefs: prefs,
                nowSecs: nowSecs,
                expectedSessionGeneration: expectedSessionGeneration
            ) {
                acknowledged.append(notification.messageId)
            }
        }
        guard !acknowledged.isEmpty else { return 0 }
        return Int(await marmot.acknowledgeNotifications(
            messageIds: acknowledged,
            expectedSessionGeneration: expectedSessionGeneration
        ))
    }

    @MainActor
    private static func render(
        _ notification: DrainNotificationInfo,
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs,
        nowSecs: UInt64,
        expectedSessionGeneration: UInt64
    ) async -> Bool {
        // A silent push can run while the app is active. Leave the durable row
        // for the model/UI path to acknowledge after repainting instead of
        // producing a foreground OS notification.
        guard UIApplication.shared.applicationState != .active else { return false }
        // Disabled notifications are a durable policy decision, not a
        // transient rendering error. ACK the row without UI so re-enabling the
        // preference cannot replay an old backlog.
        guard prefs.enabled else { return true }
        let callAction = callAction(
            control: callParseControl(content: notification.contentPreview),
            createdAtSecs: notification.createdAtSecs,
            nowSecs: nowSecs
        )
        switch callAction {
        case .acknowledge:
            return true
        case .cancel, .incomingOffer, .message:
            break
        }
        guard let renderLease = await marmot.notificationRenderLease(
            expectedSessionGeneration: expectedSessionGeneration
        ) else { return false }
        if case .cancel(let callId) = callAction {
            return await NotificationService.shared.cancelLocalNotificationAccepted(
                identifier: SonarLocalNotificationRouter.identifier(
                    idKey: callNotificationKey(groupId: notification.groupId, callId: callId),
                    kind: .call
                ),
                renderLease: renderLease
            )
        }
        let senderName = marmot.displayName(forNpub: notification.senderNpub)
            ?? String(notification.senderNpub.prefix(12)) + "…"
        let groupName = notification.groupName.isEmpty ? nil : notification.groupName
        let kind: SonarLocalNotificationKind
        let idKey: String
        switch callAction {
        case .incomingOffer(let callId):
            kind = .call
            idKey = callNotificationKey(groupId: notification.groupId, callId: callId)
        case .message:
            kind = localKind(for: notification.contentPreview)
            idKey = notification.messageId
        case .cancel, .acknowledge:
            return false
        }
        guard let routed = SonarLocalNotificationRouter.make(
            idKey: idKey,
            kind: kind,
            conversationTitle: groupName ?? senderName,
            senderName: senderName,
            groupName: groupName,
            preview: kind == .call ? nil : notification.contentPreview,
            prefs: prefs
        ) else { return false }
        return await NotificationService.shared.postLocalNotification(
            title: routed.title,
            body: routed.body,
            identifier: routed.identifier,
            renderLease: renderLease
        )
    }

    static func callAction(
        control: CallControlInfo?,
        createdAtSecs: UInt64,
        nowSecs: UInt64
    ) -> SonarPushCallAction {
        switch control {
        case let .offer(callId, _, _, unixSecs):
            let distance = nowSecs >= unixSecs ? nowSecs - unixSecs : unixSecs - nowSecs
            return distance <= 60 ? .incomingOffer(callId: callId) : .cancel(callId: callId)
        case let .answer(callId, _, _), let .cancel(callId), let .end(callId, _):
            let distance = nowSecs >= createdAtSecs
                ? nowSecs - createdAtSecs
                : createdAtSecs - nowSecs
            return distance <= 60 ? .cancel(callId: callId) : .acknowledge
        case nil:
            return .message
        }
    }

    static func callNotificationKey(groupId: String, callId: String) -> String {
        "call-\(groupId)-\(callId)"
    }

    static func isSenderBlocked(_ senderNpub: String, blockedNostr: Set<String>) -> Bool {
        let clean = senderNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex: String?
        if clean.count == 64, clean.allSatisfy({ $0.isHexDigit }) {
            hex = clean.lowercased()
        } else if let decoded = try? Bech32.decode(clean),
                  decoded.hrp == "npub", decoded.data.count == 32 {
            hex = decoded.data.map { String(format: "%02x", $0) }.joined()
        } else {
            hex = nil
        }
        return hex.map { blockedNostr.contains($0) } ?? false
    }

    private static func localKind(for content: String) -> SonarLocalNotificationKind {
        switch sonarNotificationClassifyContent(content: content) {
        case .payment: return .payment
        case .invite: return .invite
        case .mention: return .mention
        case .geohash: return .geohash
        case .network: return .network
        case .message, .call: return .message
        }
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

    // MARK: - Durable continuation

    @MainActor
    static func registerBackgroundContinuation(
        marmotProvider: @escaping @MainActor () -> MarmotChatModel?
    ) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: continuationTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                handleBackgroundContinuation(
                    processingTask,
                    marmot: marmotProvider()
                )
            }
        }
        Task { @MainActor in
            guard let marmot = marmotProvider(),
                  let ownerId = await marmot.notificationAccountOwner()
            else {
                invalidateBackgroundContinuation()
                return
            }
            var state = continuationState()
            state.clearUnlessOwned(by: ownerId)
            persistContinuationState(state)
            if state.dirty { submitBackgroundContinuation() }
        }
    }

    @MainActor
    private static func handleBackgroundContinuation(
        _ task: BGProcessingTask,
        marmot: MarmotChatModel?
    ) {
        let completion = SonarBGCompletionGate(task)
        let continuation = continuationState()
        let continuationGeneration = continuation.generation
        let ownerId = continuation.ownerId
        Task { @MainActor in
            guard let marmot,
                  let ownerId,
                  await continuationIsCurrent(
                    generation: continuationGeneration,
                    ownerId: ownerId,
                    marmot: marmot
                  )
            else {
                invalidateStaleContinuation(currentOwnerId: await marmot?.notificationAccountOwner())
                completion.finish(success: false)
                return
            }
            let outcome = await performMarmotRecovery(
                marmot: marmot,
                prefs: notificationPrefs(),
                deadline: Date().addingTimeInterval(
                    TransportConfig.marmotPushEndToEndDeadlineSeconds
                ),
                showFallback: false,
                continuationGeneration: continuationGeneration,
                ownerId: ownerId
            )
            guard !completion.isFinished else { return }
            if outcome.completed {
                clearBackgroundContinuation(
                    ifGeneration: continuationGeneration,
                    ownerId: ownerId
                )
            } else {
                rescheduleBackgroundContinuation(
                    ifGeneration: continuationGeneration,
                    ownerId: ownerId,
                    marmot: marmot
                )
            }
            completion.finish(success: outcome.completed)
        }
        task.expirationHandler = {
            // Do not cancel an in-progress native MLS transaction. Rust owns
            // that continuation; only close the OS task exactly once and leave
            // the durable dirty bit set for a later wake.
            Task { @MainActor in
                if let marmot, let ownerId {
                    rescheduleBackgroundContinuation(
                        ifGeneration: continuationGeneration,
                        ownerId: ownerId,
                        marmot: marmot
                    )
                }
                completion.finish(success: false)
            }
        }
    }

    @MainActor
    private static func claimBackgroundContinuation(ownerId: String) -> Int {
        var state = continuationState()
        state.admit(ownerId: ownerId)
        persistContinuationState(state)
        submitBackgroundContinuation()
        return state.generation
    }

    @MainActor
    private static func submitBackgroundContinuation() {
        let request = BGProcessingTaskRequest(identifier: continuationTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.warning("Unable to schedule notification continuation: \(error)")
        }
    }

    @MainActor
    private static func rescheduleBackgroundContinuation(
        ifGeneration generation: Int,
        ownerId: String,
        marmot: MarmotChatModel
    ) {
        var state = continuationState()
        // Expiration/completion callbacks from an older OS task must not spend
        // retries or clear dirtiness admitted by a newer push.
        guard state.generation == generation, state.belongs(to: ownerId) else { return }
        state.attempts &+= 1
        if state.attempts >= maximumContinuationAttempts {
            state.dirty = false
            persistContinuationState(state)
            let generation = state.generation
            Task { @MainActor in
                await showFallbackNotificationOnce(
                    marmot: marmot,
                    prefs: notificationPrefs(),
                    generation: generation,
                    ownerId: ownerId
                )
            }
            return
        }
        state.dirty = true
        persistContinuationState(state)
        submitBackgroundContinuation()
    }

    @MainActor
    private static func clearBackgroundContinuation(
        ifGeneration generation: Int,
        ownerId: String
    ) {
        var state = continuationState()
        guard state.generation == generation, state.belongs(to: ownerId) else { return }
        state.dirty = false
        state.attempts = 0
        persistContinuationState(state)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuationTaskIdentifier)
    }

    @MainActor
    private static func continuationState() -> ContinuationState {
        guard let data = UserDefaults.standard.data(forKey: continuationStateKey),
              let state = try? JSONDecoder().decode(ContinuationState.self, from: data)
        else { return ContinuationState() }
        return state
    }

    @MainActor
    private static func persistContinuationState(_ state: ContinuationState) {
        guard state.ownerId != nil else {
            UserDefaults.standard.removeObject(forKey: continuationStateKey)
            UserDefaults.standard.synchronize()
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: continuationStateKey)
        // Admission must reach the preferences plist before the push callback
        // is allowed to finish and the process can be suspended.
        UserDefaults.standard.synchronize()
    }

    /// Account replacement/wipe boundary. Persisted progress is retired before
    /// the old node can be reused, and the OS request is cancelled. Any already
    /// running callback still carries its owner and fails the owner/render fence.
    @MainActor
    static func invalidateBackgroundContinuation() {
        persistContinuationState(ContinuationState())
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuationTaskIdentifier)
    }

    @MainActor
    private static func invalidateStaleContinuation(currentOwnerId: String?) {
        var state = continuationState()
        let previous = state
        state.clearUnlessOwned(by: currentOwnerId)
        if state != previous {
            persistContinuationState(state)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuationTaskIdentifier)
        }
    }

    @MainActor
    private static func continuationIsCurrent(
        generation: Int,
        ownerId: String,
        marmot: MarmotChatModel
    ) async -> Bool {
        let currentOwnerId = await marmot.notificationAccountOwner()
        invalidateStaleContinuation(currentOwnerId: currentOwnerId)
        let state = continuationState()
        return state.generation == generation && state.belongs(to: ownerId)
    }

    @MainActor
    private static func markSurfaced(through generation: Int, ownerId: String) {
        var state = continuationState()
        guard state.belongs(to: ownerId) else { return }
        // Surface progress belongs to the captured recovery snapshot. A newer
        // admitted wake must keep its fallback obligation until that newer
        // snapshot is independently rendered.
        markRenderedSnapshotSurfaced(&state, renderedGeneration: generation)
        persistContinuationState(state)
    }

    static func markRenderedSnapshotSurfaced(
        _ state: inout ContinuationState,
        renderedGeneration: Int
    ) {
        state.markSurfaced(through: renderedGeneration)
    }

    // MARK: - Helpers

    private static func notificationPrefs() -> SonarLocalNotificationPrefs {
        SonarLocalNotificationPrefs(
            enabled: UserDefaults.standard.object(forKey: "sonar.notifications.enabled") as? Bool ?? true,
            showNames: UserDefaults.standard.object(forKey: "sonar.notifications.showNames") as? Bool ?? true,
            showPreview: UserDefaults.standard.object(forKey: "sonar.notifications.showPreview") as? Bool ?? false,
            showPaymentAmount: true
        )
    }

    @MainActor
    private static func showFallbackNotificationOnce(
        marmot: MarmotChatModel,
        prefs: SonarLocalNotificationPrefs,
        generation: Int,
        ownerId: String
    ) async {
        var state = continuationState()
        guard state.generation == generation, state.belongs(to: ownerId) else { return }
        guard await marmot.notificationAccountOwner() == ownerId else {
            invalidateStaleContinuation(
                currentOwnerId: await marmot.notificationAccountOwner()
            )
            return
        }
        guard state.needsFallback(for: generation) else { return }
        let sessionGeneration = await marmot.notificationSessionGeneration()
        guard let renderLease = await marmot.notificationRenderLease(
            expectedSessionGeneration: sessionGeneration
        ) else { return }
        guard await continuationIsCurrent(
            generation: generation,
            ownerId: ownerId,
            marmot: marmot
        ) else { return }
        guard let routed = SonarLocalNotificationRouter.make(
            idKey: "marmot-push",
            kind: .message,
            conversationTitle: nil,
            preview: nil,
            prefs: prefs
        ) else { return }
        let posted = await postFallbackWithFence(renderLease: renderLease) { lease in
            await NotificationService.shared.postLocalNotification(
                title: routed.title,
                body: routed.body,
                identifier: routed.identifier,
                renderLease: lease
            )
        }
        if posted {
            state = continuationState()
            guard state.generation == generation,
                  state.belongs(to: ownerId),
                  await marmot.notificationAccountOwner() == ownerId
            else { return }
            state.markFallback(through: generation)
            persistContinuationState(state)
        }
    }

    /// Kept independently testable so the fallback-specific suspended callback
    /// race is deterministic without depending on UNUserNotificationCenter.
    @MainActor
    static func postFallbackWithFence(
        renderLease: SonarNotificationRenderLease,
        post: @escaping @MainActor (SonarNotificationRenderLease) async -> Bool
    ) async -> Bool {
        guard renderLease.isCurrent else { return false }
        let posted = await post(renderLease)
        return posted && renderLease.isCurrent
    }

    private static var fallbackNotificationIdentifier: String {
        SonarLocalNotificationRouter.identifier(idKey: "marmot-push", kind: .message)
    }

}

#endif
