//
// SendFailureErrorTextTests.swift
// bitchatTests
//
// A send in a recovered v1 chat whose peer has not updated fails in core with
// "no key package found on relays for …". The store's failure callback reads
// `marmot.errorText` to show "Waiting for them to update Sonar"; the model
// cleared `errorText` when the send started and only set it AFTER calling the
// callback, so the store saw nil: no banner, no toast, and the discarded echo
// made the message vanish silently (QA-193 on iOS, found by
// `scripts/qa/ios-mdk-upgrade.sh`; #613 only ever checked it on Android).
//
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct SendFailureErrorTextTests {
    /// Fails without the fix: the callback observed `errorText == nil`. Every
    /// send path's catch goes through `reportSendFailure`; a unit test cannot
    /// reach the connected-then-publish-fails path itself.
    @Test
    func theFailureCallbackSeesTheSendsError() {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        // The shape core's `Error::KeyPackageNotFound` reaches the host in.
        let error = MarmotService.ServiceError.core("no key package found on relays for 3bf0c63f")
        store.marmot.errorText = nil  // a send clears it when it starts
        var seen: String?
        store.marmot.reportSendFailure(error, onFailure: {
            seen = store.marmot.errorText
        })
        #expect(seen?.isEmpty == false, "the failure callback must see the send's error")
        #expect(snMarmotSendNeedsPeerUpdate(seen ?? ""),
                "a peer still on v1 must read as 'waiting for them to update'")
    }

    /// The host matches core's `Error::KeyPackageNotFound` text; a reworded
    /// core error would silently drop the banner again.
    @Test
    func coresMissingKeyPackageErrorMeansWaitingForTheirUpdate() {
        let core = "no key package found on relays for 3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        #expect(snMarmotSendNeedsPeerUpdate(core))
        #expect(snMarmotSendUserMessage(core) == "Waiting for them to update Sonar")
        #expect(!snMarmotSendNeedsPeerUpdate("relay fetch error: timeout"))
    }
}
