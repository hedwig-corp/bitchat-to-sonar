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

    weak var store: SonarAppStore?

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
    }

    func schedule() {
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
