#if os(iOS)
import BackgroundTasks
import BitLogger
import Foundation
import UIKit

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

    /// Daily floor. Safe to call repeatedly — resubmitting replaces the pending
    /// request for the same identifier rather than stacking.
    func schedule() {
        guard registered else {
            wantsFloorSchedule = true
            return
        }
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
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: true)
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

        work = Task { @MainActor in
            defer {
                if lease != .invalid {
                    UIApplication.shared.endBackgroundTask(lease)
                    lease = .invalid
                }
            }
            await store.marmot.runAutoBackupIfDue(allowWhileActive: true)
        }
    }
}
#endif
