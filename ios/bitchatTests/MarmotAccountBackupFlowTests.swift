import Testing
@testable import Sonar

struct MarmotAccountBackupFlowTests {
    @Test
    func alwaysReconnectsAfterUploadAttempt() {
        #expect(MarmotAccountBackupFlow.mustReconnectAfterUploadAttempt())
    }

    @Test
    func uploadFailureTakesToastPriorityOverReconnectFailure() {
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: false,
            reconnected: false
        )
        #expect(outcome.shouldSurfaceUploadFailure)
        #expect(!outcome.shouldSurfaceReconnectFailure)
        #expect(!outcome.succeeded)
    }

    @Test
    func successfulUploadStillFailsWhenReconnectDoes() {
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: true,
            reconnected: false
        )
        #expect(!outcome.shouldSurfaceUploadFailure)
        #expect(outcome.shouldSurfaceReconnectFailure)
        #expect(!outcome.succeeded)
    }

    @Test
    func successRequiresUploadAndReconnect() {
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: true,
            reconnected: true
        )
        #expect(outcome.succeeded)
        #expect(!outcome.shouldSurfaceUploadFailure)
        #expect(!outcome.shouldSurfaceReconnectFailure)
    }

    @Test
    func backgroundRunWithoutReconnectRequirementSucceedsClosed() {
        // Background executors run `backupAccount(reopenAfterSeal: false)`:
        // no reconnect is attempted, the store stays CLOSED, and that absence
        // must not read as a failure (0xdead10cc round 8).
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: true,
            reconnected: false,
            reconnectRequired: false
        )
        #expect(outcome.succeeded)
        #expect(!outcome.shouldSurfaceUploadFailure)
        #expect(!outcome.shouldSurfaceReconnectFailure)
    }

    @Test
    func backgroundRunStillSurfacesUploadFailure() {
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: false,
            reconnected: false,
            reconnectRequired: false
        )
        #expect(outcome.shouldSurfaceUploadFailure)
        #expect(!outcome.shouldSurfaceReconnectFailure)
        #expect(!outcome.succeeded)
    }

    @Test
    func uploadSuccessWithFailedReconnectSurfacesReconnectError() {
        // iOS differs from Compose here on purpose: Compose swallows boot()
        // failure after a successful upload; we still tell the user reconnect
        // failed so they don't think chats are live when the node stayed closed.
        let outcome = MarmotAccountBackupFlow.outcome(
            uploadSucceeded: true,
            reconnected: false
        )
        #expect(outcome.shouldSurfaceReconnectFailure)
    }

    // MARK: - Metered-link gate (66.3 GB cellular report)

    @Test
    func automaticBackupIsBlockedOnAMeteredLinkByDefault() {
        #expect(!MarmotAccountBackupFlow.autoBackupAllowedOnCurrentPath(
            pathIsExpensive: true,
            cellularOptIn: false
        ))
    }

    @Test
    func optingInAllowsAutomaticBackupOnCellular() {
        #expect(MarmotAccountBackupFlow.autoBackupAllowedOnCurrentPath(
            pathIsExpensive: true,
            cellularOptIn: true
        ))
    }

    @Test
    func unmeteredLinksAreNeverGated() {
        #expect(MarmotAccountBackupFlow.autoBackupAllowedOnCurrentPath(
            pathIsExpensive: false,
            cellularOptIn: false
        ))
        #expect(MarmotAccountBackupFlow.autoBackupAllowedOnCurrentPath(
            pathIsExpensive: false,
            cellularOptIn: true
        ))
    }

    // MARK: - Unchanged-account no-op

    @Test
    func coreRefusalToReuploadAnUnchangedAccountIsNotAFailure() {
        // Exactly what crosses UniFFI: SonarFfiError is a flat_error, so the
        // core Display text is the whole contract.
        let unchanged = MarmotService.ServiceError.core(
            "account backup unchanged since the last successful upload"
        )
        #expect(MarmotAccountBackupFlow.isUnchangedAccount(unchanged))
    }

    @Test
    func realBackupFailuresAreStillFailures() {
        #expect(!MarmotAccountBackupFlow.isUnchangedAccount(
            MarmotService.ServiceError.core("backup upload timed out")
        ))
        #expect(!MarmotAccountBackupFlow.isUnchangedAccount(
            MarmotService.ServiceError.core("no account backup found on Blossom for this key")
        ))
    }
}
