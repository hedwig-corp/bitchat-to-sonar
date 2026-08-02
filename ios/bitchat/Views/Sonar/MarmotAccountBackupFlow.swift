//
// MarmotAccountBackupFlow.swift
// bitchat
//
// Pure host policy for Settings → Backup chats. Kept free of MarmotService so
// the reconnect-always invariant is unit-testable without UniFFI.
//

import Foundation

enum MarmotAccountBackupFlow {
    /// Outcome of one Settings backup attempt after upload + reconnect.
    struct Outcome: Equatable {
        var uploadSucceeded: Bool
        var reconnected: Bool
        /// False when the caller ran with `reopenAfterSeal: false` (background
        /// executors): no reconnect was attempted, so its absence is not a
        /// failure. The store staying CLOSED there is the point — a background
        /// reopen is what RunningBoard kills with 0xdead10cc (round 8).
        var reconnectRequired: Bool = true

        /// Prefer the upload error when both fail — matches Compose toast priority.
        var shouldSurfaceUploadFailure: Bool { !uploadSucceeded }

        var shouldSurfaceReconnectFailure: Bool {
            uploadSucceeded && reconnectRequired && !reconnected
        }

        var succeeded: Bool {
            uploadSucceeded && (!reconnectRequired || reconnected)
        }
    }

    /// Compose always reboots after backup; iOS must reconnect even when upload fails.
    /// Applies only to foreground (Settings/timer) runs — see `reconnectRequired`.
    static func mustReconnectAfterUploadAttempt() -> Bool { true }

    static func outcome(
        uploadSucceeded: Bool,
        reconnected: Bool,
        reconnectRequired: Bool = true
    ) -> Outcome {
        Outcome(
            uploadSucceeded: uploadSucceeded,
            reconnected: reconnected,
            reconnectRequired: reconnectRequired
        )
    }
}
