import Testing
@testable import Sonar

struct SNToastSessionTests {
    @Test
    func newerShowInvalidatesOlderDismiss() {
        var session = SNToastSession()
        let first = session.show("Backing up chats…")
        _ = session.show("Chat backup uploaded")
        session.clear(ifEpoch: first)
        #expect(session.text == "Chat backup uploaded")
    }

    @Test
    func matchingEpochClearsToast() {
        var session = SNToastSession()
        let epoch = session.show("Chat backup uploaded")
        session.clear(ifEpoch: epoch)
        #expect(session.text == nil)
    }

    @Test
    func stickyBumpsEpochSoPendingDismissNoops() {
        var session = SNToastSession()
        let stale = session.show("old")
        session.showSticky("Backing up chats…")
        session.clear(ifEpoch: stale)
        #expect(session.text == "Backing up chats…")
        let done = session.show("Chat backup uploaded")
        session.clear(ifEpoch: done)
        #expect(session.text == nil)
    }

    @Test
    func resetClearsAndInvalidatesPendingDismiss() {
        var session = SNToastSession()
        let stale = session.show("Chat backup uploaded")
        session.reset()
        #expect(session.text == nil)
        session.clear(ifEpoch: stale)
        #expect(session.text == nil)
    }

    @Test
    func dismissMustNotClobberUnrelatedPublishedToast() {
        // Mirrors SonarAppStore.showToast dismiss: clear session on epoch match,
        // but only nil the published toast when it still equals the shown text.
        var session = SNToastSession()
        let epoch = session.show("Chat backup uploaded")
        var published: String? = "Chat backup uploaded"
        published = "Join request sent" // legacy/direct writer mid-flight
        if session.epoch == epoch {
            if published == "Chat backup uploaded" {
                session.clear(ifEpoch: epoch)
                published = nil
            } else {
                session.clear(ifEpoch: epoch)
            }
        }
        #expect(published == "Join request sent")
        #expect(session.text == nil)
    }
}
