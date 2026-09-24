//
// MediaTransferSourceTests.swift
// bitchatTests
//
// The UIKit transcript host reconfigures a cell only when the transcript's
// render revision changes; a download finishing does not change it. Media
// bubbles therefore observe `SNMediaTransferSource`, and every transfer-state
// change in the store must reach it — otherwise a received photo keeps its
// "Tap to download" placeholder after the file is already on disk.
//

import Combine
import Foundation
import Testing
@testable import Sonar

@MainActor
@Suite(.serialized)
struct MediaTransferSourceTests {
    @Test
    func everyDownloadStateChangeReachesTheBubbleSource() async throws {
        let (store, cleanup) = makeIsolatedSonarAppStore()
        defer { cleanup() }
        // No group id: the download fails fast without touching the network,
        // walking the same notDownloaded -> downloading -> failed transitions a
        // real attachment walks.
        let item = SNMediaItem(
            url: "https://blossom.invalid/\(UUID().uuidString)",
            mime: "image/png",
            filename: "photo.png",
            groupId: ""
        )
        let start = store.mediaTransferSource.revision

        store.requestMediaDownload(item)
        #expect(store.mediaTransferState(item).phase == .downloading)
        #expect(store.mediaTransferSource.revision > start, "downloading must repaint the bubble")
        let afterStart = store.mediaTransferSource.revision

        for _ in 0..<300 where store.mediaTransferState(item).phase == .downloading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(store.mediaTransferState(item).phase == .failed)
        #expect(
            store.mediaTransferSource.revision > afterStart,
            "the terminal phase must repaint the bubble, not wait for a transcript rebuild"
        )
    }

    /// The core reports upload progress every 100 ms for the whole upload —
    /// including the wait for the Blossom response once every byte is sent,
    /// measured at ~60 s (600 ticks at fraction 1). Each publish invalidates the
    /// whole store, so a repeat of the same fraction must not publish.
    @Test
    func repeatedUploadProgressDoesNotRepublish() {
        let suiteName = "MediaTransferSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MarmotChatModel(
            service: MarmotService(relayUrls: []),
            keychain: MockKeychain(),
            defaults: defaults
        )
        var publishes = 0
        let subscription = model.$mediaUploadProgress.dropFirst().sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        model.noteMediaUploadProgress("optimistic-upload", 0.5)
        for _ in 0..<10 {
            model.noteMediaUploadProgress("optimistic-upload", 1)
        }

        #expect(publishes == 2, "0.5 and 1.0 are the only real movements")
        #expect(model.mediaUploadProgress["optimistic-upload"] == 1)
        #expect(model.mediaUploadProgressSource.fractions["optimistic-upload"] == 1)
    }
}
