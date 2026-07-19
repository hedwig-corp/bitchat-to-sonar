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
}
