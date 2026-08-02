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

    /// `UserDefaults` key for "back up over cellular". Off by default: an
    /// account backup is a multi-megabyte full-snapshot upload, and shipping it
    /// over a metered link by default cost one roaming user 66.3 GB in a single
    /// billing period.
    static let cellularOptInKey = "sonar.auto_backup_cellular"

    /// Whether an AUTOMATIC backup may run on the current route.
    ///
    /// Manual "Back up now" deliberately does not consult this — the user asked
    /// for it and can see the result.
    ///
    /// Never let this become "no backups at all": the Backup screen shows the
    /// age of the last successful upload next to the toggle, so a user who is
    /// permanently on cellular can see the staleness and opt in. Silent
    /// indefinite skipping would be an Account Key Durability problem, not a
    /// data saving.
    static func autoBackupAllowedOnCurrentPath(
        pathIsExpensive: Bool,
        cellularOptIn: Bool
    ) -> Bool {
        !pathIsExpensive || cellularOptIn
    }

    /// Stable Display text of `sonar_core::Error::AccountBackupUnchanged`.
    ///
    /// Errors cross UniFFI as rendered strings (`SonarFfiError` is a
    /// `flat_error`), so matching the message is the contract here — the same
    /// one `AccountBackupMissing` already relies on. Kept to the distinctive
    /// stem so a reworded tail cannot silently turn a no-op back into a
    /// user-visible failure.
    private static let unchangedAccountMarker = "account backup unchanged"

    /// True when core refused to re-seal because the account is byte-identical
    /// to the blob already on Blossom.
    ///
    /// This is a **no-op, not a failure**: nothing needs uploading. Callers must
    /// not write it to `last_error` (it would put a red row under a perfectly
    /// backed-up account) and must not surface it as a failed backup.
    static func isUnchangedAccount(_ error: Error) -> Bool {
        let text = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        if text.localizedCaseInsensitiveContains(unchangedAccountMarker) {
            return true
        }
        // `String(describing:)` on some bridged error shapes hides the message;
        // `localizedDescription` is the other rendering hosts see.
        return error.localizedDescription.localizedCaseInsensitiveContains(unchangedAccountMarker)
    }
}
