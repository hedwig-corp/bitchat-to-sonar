import Testing
@testable import Sonar

/// QA-151: a bubble that is still sending (or failed) must not be announced
/// as "Sent at …". The sighted footer already tells the truth; VoiceOver and
/// the headless QA driver read this label instead.
struct SNBubbleDeliveryAccessibilityLabelTests {

    @Test
    func pendingRowsAnnounceTheirState() {
        #expect(
            snBubbleDeliveryAccessibilityLabel(
                stateText: "Sending · internet", isPending: true, isFailed: false, time: "8:10 PM"
            ) == "Sending"
        )
        #expect(
            snBubbleDeliveryAccessibilityLabel(
                stateText: "Uploading", isPending: true, isFailed: false, time: "8:10 PM"
            ) == "Uploading"
        )
    }

    @Test
    func failedRowsAnnounceTheFailure() {
        #expect(
            snBubbleDeliveryAccessibilityLabel(
                stateText: "Couldn't send · internet", isPending: false, isFailed: true, time: "8:10 PM"
            ) == "Couldn't send"
        )
    }

    @Test
    func sentAndInboundRowsAnnounceTheTime() {
        #expect(
            snBubbleDeliveryAccessibilityLabel(
                stateText: "Sent · internet", isPending: false, isFailed: false, time: "8:10 PM"
            ) == "Sent at 8:10 PM"
        )
        #expect(
            snBubbleDeliveryAccessibilityLabel(
                stateText: nil, isPending: false, isFailed: false, time: "8:10 PM"
            ) == "Sent at 8:10 PM"
        )
    }
}
