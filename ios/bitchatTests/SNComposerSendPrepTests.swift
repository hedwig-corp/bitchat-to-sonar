//
// SNComposerSendPrepTests.swift
// bitchatTests
//
// Regression: UIKit transcript host refreshes the hosted composer inside
// onSend. Draft must be prepared/cleared before that callback, matching
// Compose (`draft = ""` then send).
//

import Testing
@testable import Sonar

struct SNComposerSendPrepTests {

    @Test
    func prepareSendTrimsAndRejectsBlank() {
        #expect(snPrepareComposerSend(text: "  hello  ") == "hello")
        #expect(snPrepareComposerSend(text: "\n\t") == nil)
        #expect(snPrepareComposerSend(text: "") == nil)
    }

    @Test
    func prepareSendKeepsMultiLinePayload() {
        let multi = "Yes but then you should also\nmake the gateway better"
        #expect(snPrepareComposerSend(text: multi) == multi)
    }
}
