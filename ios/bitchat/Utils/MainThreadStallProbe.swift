import BitLogger
import Foundation

/// Diagnostics: names the main-actor work that is running when the main
/// thread stops answering. A utility thread pings the main queue twice a
/// second. A ping that waits longer than `stallThresholdMs` logs the sections
/// active at that moment, while the stall is still going, and the total once
/// the main thread comes back. Sections are entered with `measure`, which also
/// logs any single section slower than `sectionThresholdMs`.
///
/// A stall with no active section means the time is spent outside the
/// instrumented sites (a SwiftUI body, a sink that is not wrapped), which is
/// itself the answer the log is for. Costs: one sleeping thread, one main
/// queue block per 500 ms, and a lock take per section.
enum SNMainThreadStallProbe {
    private static let stallThresholdMs: Double = 250
    private static let sectionThresholdMs: Double = 48
    private static let pingInterval: TimeInterval = 0.5

    private static let lock = NSLock()
    private static var started = false
    /// name → when the section was entered. Nested sections are listed together.
    private static var activeSections: [String: CFAbsoluteTime] = [:]
    private static var pendingPingSentAt: CFAbsoluteTime?
    private static var reportedPendingStall = false

    static func start() {
        lock.lock()
        let shouldStart = !started
        started = true
        lock.unlock()
        guard shouldStart else { return }
        let thread = Thread { pingLoop() }
        thread.name = "sonar.mainThreadStallProbe"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Run `body` as a named main-actor section.
    @MainActor
    static func measure<T>(_ name: String, _ body: @MainActor () throws -> T) rethrows -> T {
        let entered = CFAbsoluteTimeGetCurrent()
        lock.lock()
        activeSections[name] = entered
        lock.unlock()
        defer {
            lock.lock()
            activeSections[name] = nil
            lock.unlock()
            let ms = (CFAbsoluteTimeGetCurrent() - entered) * 1000
            if ms > sectionThresholdMs {
                SecureLogger.info(
                    "main-thread section slow name=\(name) ms=\(Int(ms.rounded()))",
                    category: .session
                )
            }
        }
        return try body()
    }

    private static func pingLoop() {
        while true {
            Thread.sleep(forTimeInterval: pingInterval)
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            if let sent = pendingPingSentAt {
                // The previous ping is still waiting: the main thread is busy.
                let waitedMs = (now - sent) * 1000
                let report = waitedMs > stallThresholdMs && !reportedPendingStall
                if report { reportedPendingStall = true }
                let sections = activeSections
                    .map { "\($0.key)+\(Int(((now - $0.value) * 1000).rounded()))ms" }
                    .sorted()
                lock.unlock()
                if report {
                    SecureLogger.warning(
                        "main thread stalled ms=\(Int(waitedMs.rounded())) sections=\(sections)",
                        category: .session
                    )
                }
                continue
            }
            pendingPingSentAt = now
            reportedPendingStall = false
            lock.unlock()
            DispatchQueue.main.async {
                let received = CFAbsoluteTimeGetCurrent()
                lock.lock()
                let sent = pendingPingSentAt
                let reported = reportedPendingStall
                pendingPingSentAt = nil
                lock.unlock()
                guard let sent, reported else { return }
                SecureLogger.warning(
                    "main thread stall ended ms=\(Int(((received - sent) * 1000).rounded()))",
                    category: .session
                )
            }
        }
    }
}
