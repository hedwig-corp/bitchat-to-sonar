import Foundation
import UserNotifications
import XCTest
@testable import Sonar

final class NotificationServiceTests: XCTestCase {
    func testPanicAfterRelaunchCancelsNotificationsUnknownToNewProcess() {
        var cancelledAll = 0
        let relaunchedService = NotificationService(
            testEnvironment: { false },
            cancelAll: { cancelledAll += 1 }
        )

        // This instance has no in-memory identifiers, matching a relaunch after
        // the old process already delivered its notification.
        relaunchedService.suspendAccountNotifications()

        XCTAssertEqual(cancelledAll, 1)
    }

    func testSubmissionAwaitsNotificationCenterAcceptance() async {
        var completion: ((Error?) -> Void)?
        let submitted = expectation(description: "notification center received request")
        let service = NotificationService(
            testEnvironment: { false },
            submitter: { _, callback in
                completion = callback
                submitted.fulfill()
            }
        )
        let task = Task {
            await service.sendPrivateMessageNotification(
                from: "Peer",
                message: "secret",
                peerID: PeerID(str: "peer"),
                messageID: "stable-id"
            )
        }
        await fulfillment(of: [submitted], timeout: 1)
        XCTAssertNotNil(completion)
        completion?(nil)
        let outcome = await task.value
        XCTAssertEqual(outcome, .submitted)
    }

    func testSubmissionFailureRemainsRetryable() async {
        let service = NotificationService(
            testEnvironment: { false },
            submitter: { _, callback in
                callback(NSError(domain: "notification-test", code: 1))
            }
        )
        let outcome = await service.sendPrivateMessageNotification(
            from: "Peer",
            message: "secret",
            peerID: PeerID(str: "peer"),
            messageID: "stable-id"
        )
        XCTAssertEqual(outcome, .retryableFailure)
    }

    func testTestEnvironmentIsExplicitTerminalSuppression() async {
        let service = NotificationService(
            testEnvironment: { true },
            submitter: { _, _ in XCTFail("suppressed notifications must not submit") }
        )
        let outcome = await service.sendPrivateMessageNotification(
            from: "Peer",
            message: "secret",
            peerID: PeerID(str: "peer")
        )
        XCTAssertEqual(outcome, .terminallySuppressed)
    }

    func testNotificationsDisabledIsExplicitTerminalSuppression() async {
        let service = NotificationService(
            testEnvironment: { false },
            submitter: { _, callback in
                callback(NSError(
                    domain: UNErrorDomain,
                    code: UNError.Code.notificationsNotAllowed.rawValue
                ))
            }
        )
        let outcome = await service.sendPrivateMessageNotification(
            from: "Peer",
            message: "secret",
            peerID: PeerID(str: "peer")
        )
        XCTAssertEqual(outcome, .terminallySuppressed)
    }

    func testSuspendedSubmissionIsCancelledAndCannotAcknowledgeOldGeneration() async {
        var completions: [((Error?) -> Void)] = []
        var cancelled: [[String]] = []
        var submittedIdentifiers: [String] = []
        let submitted = expectation(description: "old generation reached platform submitter")
        let replacementSubmitted = expectation(description: "replacement generation submitted")
        let service = NotificationService(
            testEnvironment: { false },
            submitter: { request, callback in
                submittedIdentifiers.append(request.identifier)
                completions.append(callback)
                if completions.count == 1 {
                    submitted.fulfill()
                } else {
                    replacementSubmitted.fulfill()
                }
            },
            canceller: { cancelled.append($0) }
        )

        let oldRender = Task {
            await service.sendPrivateMessageNotification(
                from: "Old peer",
                message: "secret",
                peerID: PeerID(str: "old-peer"),
                messageID: "old-message"
            )
        }
        await fulfillment(of: [submitted], timeout: 1)

        service.suspendAccountNotifications()
        completions[0](nil)

        let oldOutcome = await oldRender.value
        XCTAssertEqual(oldOutcome, .retryableFailure)
        XCTAssertTrue(cancelled.flatMap { $0 }.contains(submittedIdentifiers[0]))

        XCTAssertTrue(service.reactivateAccountNotifications(markerPending: { false }))
        let newRender = Task {
            await service.sendPrivateMessageNotification(
                from: "New peer",
                message: "new",
                peerID: PeerID(str: "new-peer"),
                messageID: "new-message"
            )
        }
        await fulfillment(of: [replacementSubmitted], timeout: 1)
        completions[1](nil)
        let newOutcome = await newRender.value
        XCTAssertEqual(newOutcome, .submitted)
    }

    func testRetiredSameLogicalIDCallbackCannotCancelReactivatedRequest() async {
        var completions: [((Error?) -> Void)] = []
        var submittedIdentifiers: [String] = []
        var cancelled: [[String]] = []
        let oldSubmitted = expectation(description: "old generation submitted")
        let newSubmitted = expectation(description: "new generation submitted")
        let service = NotificationService(
            testEnvironment: { false },
            submitter: { request, callback in
                submittedIdentifiers.append(request.identifier)
                completions.append(callback)
                if completions.count == 1 {
                    oldSubmitted.fulfill()
                } else {
                    newSubmitted.fulfill()
                }
            },
            canceller: { cancelled.append($0) }
        )

        let oldRender = Task {
            await service.sendPrivateMessageNotification(
                from: "Old peer",
                message: "old",
                peerID: PeerID(str: "old-peer"),
                messageID: "same-logical-id"
            )
        }
        await fulfillment(of: [oldSubmitted], timeout: 1)
        let oldPlatformIdentifier = submittedIdentifiers[0]

        service.suspendAccountNotifications()
        XCTAssertTrue(service.reactivateAccountNotifications(markerPending: { false }))

        let newRender = Task {
            await service.sendPrivateMessageNotification(
                from: "New peer",
                message: "new",
                peerID: PeerID(str: "new-peer"),
                messageID: "same-logical-id"
            )
        }
        await fulfillment(of: [newSubmitted], timeout: 1)
        let newPlatformIdentifier = submittedIdentifiers[1]
        XCTAssertNotEqual(oldPlatformIdentifier, newPlatformIdentifier)

        // Complete the retired request only after its logical replacement has
        // reached UserNotifications. It may cancel itself, never the new ID.
        completions[0](nil)
        let oldOutcome = await oldRender.value
        XCTAssertEqual(oldOutcome, .retryableFailure)
        XCTAssertFalse(cancelled.flatMap { $0 }.contains(newPlatformIdentifier))

        completions[1](nil)
        let newOutcome = await newRender.value
        XCTAssertEqual(newOutcome, .submitted)
        XCTAssertFalse(cancelled.flatMap { $0 }.contains(newPlatformIdentifier))
    }

    func testReactivationFailsWhileDurableMarkerIsPending() {
        let service = NotificationService(testEnvironment: { false })
        service.suspendAccountNotifications()
        XCTAssertFalse(service.reactivateAccountNotifications(markerPending: { true }))
    }
}
