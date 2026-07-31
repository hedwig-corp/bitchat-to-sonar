#if os(iOS)
import BackgroundTasks
import BitLogger
import Foundation
import UIKit

/// Calls `setTaskCompleted` at most once for a `BGTask`.
///
/// Both the expiration handler and the normal completion path can reach it when
/// expiry lands while the backup is finishing, and BGTaskScheduler treats a
/// second `setTaskCompleted` as a programming error. Same once-only shape as
/// `MarmotChatModel.SNBackgroundTaskBox`.
private final class SNBackupTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGTask?

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        let pending = task
        task = nil
        lock.unlock()
        pending?.setTaskCompleted(success: success)
    }
}

/// OS-scheduled auto-backup for when the UI is not in the foreground.
///
/// Two requests, mirroring the Compose app's two WorkManager jobs, because one
/// cannot do both halves:
///
/// * **near-term** (`BGAppRefreshTask`, ~3 min) — Android enqueues a one-shot
///   worker when the app backgrounds so a session's chats are safe in minutes
///   rather than at the next daily floor. Without it, an opportunistic run that
///   loses its background window (below) has no second chance for 12 hours.
/// * **floor** (`BGProcessingTask`, 12 h) — a backup is seal + reconnect +
///   upload over a network we do not control. `BGAppRefresh` budgets seconds;
///   the Android worker gets minutes, and `BGProcessing` is the Apple-sanctioned
///   equivalent for maintenance work that needs real runtime and connectivity.
///
/// Both handlers re-check disclosure and core `backup_is_due`, so whichever
/// fires second degrades to a no-op instead of backing up twice.
@MainActor
final class AutoBackupBackgroundScheduler {
    static let shared = AutoBackupBackgroundScheduler()
    /// Near-term retry after the app backgrounds.
    static let taskIdentifier = "sh.hedwig.sonar.auto-backup"
    /// Daily floor with a real execution window.
    static let processingTaskIdentifier = "sh.hedwig.sonar.auto-backup-long"

    /// Minimum background execution window (seconds) we require before we'll
    /// start an opportunistic backup. See `runOpportunisticBackgroundBackupIfDue()`.
    private static let minimumBackgroundWindowSeconds: TimeInterval = 25
    private static let nearTermDelaySeconds: TimeInterval = 3 * 60
    private static let floorDelaySeconds: TimeInterval = 12 * 60 * 60

    weak var store: SonarAppStore?

    /// `submit` before `register` does not fail with a catchable NSError — it
    /// throws an ObjC NSInternalInconsistencyException that Swift's `try`
    /// cannot catch, and the app dies at launch. Proven on the simulator:
    /// `BitchatApp.init()` schedules (disclosure already persisted) before
    /// `didFinishLaunching` registers, and every cold start crashed. So a
    /// schedule that arrives early is remembered and flushed by `register()`.
    private var registered = false
    private var wantsFloorSchedule = false
    private var wantsNearTermSchedule = false

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor in
                await self?.handle(task, label: "BGAppRefresh")
            }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor in
                await self?.handle(task, label: "BGProcessing")
            }
        }
        registered = true
        if wantsFloorSchedule {
            wantsFloorSchedule = false
            schedule()
        }
        if wantsNearTermSchedule {
            wantsNearTermSchedule = false
            scheduleSoon()
        }
    }

    /// Daily floor.
    ///
    /// Resubmitting for the same identifier replaces the pending request rather
    /// than stacking — but replacing it also RESETS `earliestBeginDate` to
    /// another 12 hours out. This runs on every transition to `.background`, so
    /// blind resubmission pushed the floor forward forever and it could never
    /// come due: any user who backgrounds the app more often than every 12
    /// hours never got the floor at all.
    ///
    /// Measured on an iPhone 14 Pro Max across a 53-hour log: 18 `BGAppRefresh`
    /// runs (the near-term path, which re-arms deliberately) and **0**
    /// `BGProcessing` runs. No submit ever failed — iOS simply never had an
    /// eligible request to launch.
    ///
    /// So only arm the floor when one is not already pending. After the handler
    /// runs, the pending request has been consumed and this re-arms normally.
    func schedule() {
        guard registered else {
            wantsFloorSchedule = true
            return
        }
        BGTaskScheduler.shared.getPendingTaskRequests { pending in
            guard !pending.contains(where: { $0.identifier == Self.processingTaskIdentifier }) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.submitFloorRequest()
            }
        }
    }

    private func submitFloorRequest() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.floorDelaySeconds)
        // Uploading is the point; running without a network would burn the slot
        // on a guaranteed failure. External power is NOT required — a backup
        // that only happens while charging is not a backup for most people.
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        submit(request, label: "BGProcessing floor")
    }

    /// Near-term retry, for the app backgrounding. Mirrors the Compose one-shot.
    func scheduleSoon() {
        guard registered else {
            wantsNearTermSchedule = true
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.nearTermDelaySeconds)
        submit(request, label: "BGAppRefresh near-term")
    }

    private func submit(_ request: BGTaskRequest, label: String) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator never runs these and refuses the submit; a device with
            // Background App Refresh switched off does the same. Neither is
            // fatal — the in-process paths still back up.
            SecureLogger.warning(
                "⚠️ Auto-backup \(label) schedule failed: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    private func handle(_ task: BGTask, label: String) async {
        // Re-arm the floor first: an early return below must not leave the app
        // with no pending background work at all.
        schedule()
        guard let store else {
            SecureLogger.warning(
                "⚠️ Auto-backup \(label): store nil (cold launch wiring missed?)",
                category: .session
            )
            task.setTaskCompleted(success: false)
            return
        }
        guard store.isAutoBackupDisclosed() else {
            task.setTaskCompleted(success: true)
            return
        }
        SecureLogger.info("Auto-backup \(label): running", category: .session)
        let work = Task { @MainActor in
            await store.marmot.runAutoBackupIfDue(allowWhileActive: true)
        }
        // `setTaskCompleted` is a once-only call; the expiration handler and the
        // normal completion below can both reach it when expiry lands while
        // `work` is finishing.
        let completion = SNBackupTaskCompletion(task)
        // Cancelling `work` is NOT enough to make suspension safe, and on its own
        // it is close to a no-op here: `backupAccount()` parks in uncancellable
        // Rust (seal, reconnect, Blossom upload), and Swift cancellation cannot
        // end such a park — the same thing `SonarPushProcessor.closeStoreWithDeadline`
        // documents for the push wake. See the close below for why expiry has to
        // close the store, not just cancel.
        // Unconditional close here, unlike the completion path below: expiry
        // cannot know whether `backupAccount()` had reached its reopen yet, and
        // the run is being abandoned regardless. `closeNode()` is idempotent.
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
            Task { @MainActor [weak self] in
                await self?.closeStoreIfStillBackgrounded(label: "\(label) expired")
            }
        }
        // The return value is the "did we reopen the store" answer the close
        // below needs.
        let reopenedStore = await work.value
        // A BGTask launch never gets a scenePhase `.background` transition, so
        // `SonarAppStore.setForeground(false)` -> `marmot.suspendStoreForBackground()`
        // — the hook that closes the SQLCipher store before suspension — never
        // runs for this process. And `backupAccount()` deliberately ends with the
        // store REOPENED: it closes the node to seal, then `performConnect()` +
        // `connectRelaysIfNeeded()` + `startPolling()` so the Blossom upload has a
        // live node. Returning here without closing therefore hands iOS a process
        // holding the App Group flock and the SQLCipher WAL the instant
        // `setTaskCompleted` lets it suspend us — RunningBoard 0xdead10cc, round 6
        // (TestFlight 1.12.6 (34), iPhone15,3: killed 28 min into a background
        // launch with a freshly installed, never-latched node — `register_push_token`
        // parked in `block_on_suspendable` un-aborted, which is R-028's proof that
        // no `interruptNodeForSuspend()` ever ran, plus `wait_for_marmot_event`
        // from the polling loop `backupAccount()` restarts).
        //
        // Close BEFORE `setTaskCompleted`, and on the ordinary success path — not
        // only on expiry. The kill needs no expiry at all: a backup that finishes
        // comfortably inside its window still leaves the store open.
        //
        // Only when the backup actually ran, though. On the not-due / not-
        // disclosed / busy paths nothing of ours is open, and a Transponder push
        // wake may have opened the node for its own drain in the meantime —
        // closing that out from under it would trade this crash for lost messages.
        if reopenedStore {
            await closeStoreIfStillBackgrounded(label: label)
        }
        completion.complete(success: true)
    }

    /// Release the SQLCipher handle + App Group flock a background auto-backup
    /// reopened, so iOS cannot suspend us holding them.
    ///
    /// Gated on `.background` like every other close path in the app: `.active`
    /// / `.inactive` means the user can see the app and the foreground path owns
    /// the node, so closing would just stall a visible session. `closeNode()` is
    /// idempotent and clears its own fence, so running this after an expiry
    /// close — or after the foreground resume already reconnected — is safe.
    ///
    /// Callers must have established that a backup really ran; see the
    /// `reopenedStore` gate in `handle(_:label:)`.
    private func closeStoreIfStillBackgrounded(label: String) async {
        guard let store else { return }
        guard UIApplication.shared.applicationState == .background else {
            SecureLogger.info(
                "Auto-backup \(label): store left open — app is foreground, that path owns the node",
                category: .session
            )
            return
        }
        SecureLogger.info("Auto-backup \(label): closing the store before suspension", category: .session)
        // Holds a `UIApplication` background task across the close, so iOS keeps
        // the process alive until the handle is actually released — that is why
        // this is also safe to start from the expiration handler, which must let
        // `setTaskCompleted` return promptly.
        await store.marmot.closeStoreAfterBackgroundWake()
        SecureLogger.info("Auto-backup \(label): store closed", category: .session)
    }

    /// Finish an in-flight due backup when the user backgrounds the app.
    func runOpportunisticBackgroundBackupIfDue() {
        guard let store, store.isAutoBackupDisclosed() else { return }

        var lease = UIBackgroundTaskIdentifier.invalid
        var work: Task<Void, Never>?
        lease = UIApplication.shared.beginBackgroundTask(withName: "sonar-auto-backup") {
            work?.cancel()
            if lease != .invalid {
                UIApplication.shared.endBackgroundTask(lease)
                lease = .invalid
            }
        }

        // Read the time budget *after* starting the lease:
        // `backgroundTimeRemaining` reports `.greatestFiniteMagnitude` until a
        // background task is active (or while still in the foreground), so we
        // need the lease in flight to get a real number. `.greatestFiniteMagnitude`
        // itself means "plenty of time" and must not fail this check.
        //
        // WHY this guard exists: `runAutoBackupIfDue()` -> `backupAccount()`
        // closes the node, seals (checkpoint + AEAD), then RECONNECTS THE NODE —
        // which reopens the SQLCipher store — before uploading to Blossom over a
        // network we do not control. If the system suspends us with that reopened
        // store open, we hit `0xdead10cc` (the watchdog kill this repo has
        // already fixed four times). The 12-hour `BGAppRefresh` path stays as the
        // fallback, so skipping the opportunistic run here is safe.
        let remaining = UIApplication.shared.backgroundTimeRemaining
        if remaining < Self.minimumBackgroundWindowSeconds,
           remaining != .greatestFiniteMagnitude {
            SecureLogger.info(
                "Auto-backup: skipped opportunistic run — background window too short "
                    + "(\(String(format: "%.1f", remaining))s < "
                    + "\(Int(Self.minimumBackgroundWindowSeconds))s). "
                    + "Relying on the 12-hour BGAppRefresh fallback.",
                category: .session
            )
            if lease != .invalid {
                UIApplication.shared.endBackgroundTask(lease)
                lease = .invalid
            }
            return
        }

        work = Task { @MainActor [weak self] in
            defer {
                if lease != .invalid {
                    UIApplication.shared.endBackgroundTask(lease)
                    lease = .invalid
                }
            }
            // Same reopen as the BGTask path, with an extra twist: this runs from
            // the scenePhase `.background` case, which calls
            // `sonarStore.setForeground(false)` -> `suspendStoreForBackground()`
            // FIRST. So the backup's `performConnect()` reopens the store behind a
            // close that has already been armed — a reopen-after-close (R-020)
            // that nothing downstream closes again. The window guard above only
            // makes it less likely to start, never safe to finish.
            //
            // Same `reopenedStore` gate as the BGTask path, and it matters more
            // here: this fires on EVERY backgrounding, so closing unconditionally
            // would race the store open for a push wake that arrived seconds after
            // the transition.
            guard await store.marmot.runAutoBackupIfDue(allowWhileActive: true) else { return }
            await self?.closeStoreIfStillBackgrounded(label: "opportunistic")
        }
    }
}
#endif
