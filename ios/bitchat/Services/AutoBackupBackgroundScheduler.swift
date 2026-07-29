#if os(iOS)
import BackgroundTasks
import BitLogger
import Foundation
import UIKit

/// Registers `BGAppRefreshTask` for opportunistic auto-backup when the UI is
/// not in the foreground. Handler honors disclosure + core `backup_is_due`.
@MainActor
final class AutoBackupBackgroundScheduler {
    static let shared = AutoBackupBackgroundScheduler()
    static let taskIdentifier = "sh.hedwig.sonar.auto-backup"

    /// Minimum background execution window (seconds) we require before we'll
    /// start an opportunistic backup. See `runOpportunisticBackgroundBackupIfDue()`.
    private static let minimumBackgroundWindowSeconds: TimeInterval = 25

    weak var store: SonarAppStore?

    /// `submit` before `register` does not fail with a catchable NSError — it
    /// throws an ObjC NSInternalInconsistencyException that Swift's `try`
    /// cannot catch, and the app dies at launch. Proven on the simulator:
    /// `BitchatApp.init()` schedules (disclosure already persisted) before
    /// `didFinishLaunching` registers, and every cold start crashed. So a
    /// schedule that arrives early is remembered and flushed by `register()`.
    private var registered = false
    private var wantsSchedule = false

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self?.handle(refresh)
            }
        }
        registered = true
        if wantsSchedule {
            wantsSchedule = false
            schedule()
        }
    }

    func schedule() {
        guard registered else {
            wantsSchedule = true
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            SecureLogger.warning(
                "⚠️ Auto-backup BGAppRefresh schedule failed: \(error.localizedDescription)",
                category: .session
            )
        }
    }

    private func handle(_ task: BGAppRefreshTask) async {
        schedule()
        guard let store else {
            SecureLogger.warning(
                "⚠️ Auto-backup BGAppRefresh: store nil (cold launch wiring missed?)",
                category: .session
            )
            task.setTaskCompleted(success: false)
            return
        }
        guard store.isAutoBackupDisclosed() else {
            task.setTaskCompleted(success: true)
            return
        }
        let work = Task { @MainActor in
            await store.marmot.runAutoBackupIfDue()
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
            await store.marmot.runAutoBackupIfDue()
        }
    }
}
#endif
