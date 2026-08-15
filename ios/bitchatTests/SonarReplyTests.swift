import Foundation
import Testing
@testable import Sonar

struct SonarReplyTests {
    @Test
    func nipC7RequiresEventIdHexAndNpub() {
        let id = String(repeating: "ab", count: 32)
        #expect(snCanEmitNipC7(parentId: id, parentNpub: "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"))
        #expect(!snCanEmitNipC7(parentId: "optimistic-1", parentNpub: "npub1abc"))
        #expect(!snCanEmitNipC7(parentId: id, parentNpub: nil))
        #expect(!snCanEmitNipC7(parentId: id, parentNpub: "hex-not-npub"))
    }

    @Test
    func replyDisabledOnOptimisticAndSendingRows() {
        let live = SNMessage(id: String(repeating: "ab", count: 32), text: "hi", time: "10:00")
        #expect(snCanReply(to: live))
        #expect(!snCanReply(to: SNMessage(id: "optimistic-1", text: "hi", time: "10:00")))
        #expect(!snCanReply(to: SNMessage(id: "failed-1", text: "hi", time: "10:00")))
        var sending = live
        sending.state = "Sending"
        #expect(!snCanReply(to: sending))
    }
}
