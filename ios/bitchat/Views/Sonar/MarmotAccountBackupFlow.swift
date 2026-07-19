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

        /// Prefer the upload error when both fail — matches Compose toast priority.
        var shouldSurfaceUploadFailure: Bool { !uploadSucceeded }

        var shouldSurfaceReconnectFailure: Bool {
            uploadSucceeded && !reconnected
        }

        var succeeded: Bool {
            uploadSucceeded && reconnected
        }
    }

    /// Compose always reboots after backup; iOS must reconnect even when upload fails.
    static func mustReconnectAfterUploadAttempt() -> Bool { true }

    static func outcome(uploadSucceeded: Bool, reconnected: Bool) -> Outcome {
        Outcome(uploadSucceeded: uploadSucceeded, reconnected: reconnected)
    }
}
