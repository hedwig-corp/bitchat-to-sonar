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
}
