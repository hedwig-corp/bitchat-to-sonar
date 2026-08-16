#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import Sonar

@MainActor
struct SNMediaPipelineUpdateTests {
    private final class TransferProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var state: SNMediaTransferState = .notDownloaded
        private var reads = 0

        func read() -> SNMediaTransferState {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return state
        }

        func set(_ state: SNMediaTransferState) {
            lock.lock()
            self.state = state
            lock.unlock()
        }

        func readCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
    }

    @Test
    func hostedAlbumRerendersWhenTransferStateChanges() async throws {
        let updates = SNMediaPipelineUpdates()
        let probe = TransferProbe()
        let media = [
            SNMediaItem(
                url: "https://blossom.example/one",
                mime: "image/jpeg",
                filename: "one.jpg",
                groupId: "group"
            ),
            SNMediaItem(
                url: "https://blossom.example/two",
                mime: "image/jpeg",
                filename: "two.jpg",
                groupId: "group"
            ),
        ]
        let message = SNMessage(id: "album", text: "", time: "19:47", media: media)
        let pipeline = SNMediaPipeline(
            state: { _ in probe.read() },
            prepare: { _, _ in },
            request: { _ in },
            cancel: { _ in },
            loadLocal: { _ in nil },
            updates: updates
        )
        let host = UIHostingController(
            rootView: SNMediaBubble(m: message, maxBubbleWidth: 280, pipeline: pipeline)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        let readsBeforeChange = probe.readCount()
        probe.set(.downloading(nil))
        updates.invalidate()
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutIfNeeded()

        #expect(probe.readCount() > readsBeforeChange)
    }
}
#endif
