import TranscriptEngine
import UIKit

/// Sketch: string rows in a full-height collection with owned bottom inset.
/// Real apps supply cell configuration + DB paging; this shows policy imports only.
final class SampleTranscriptHostViewController: UIViewController {
    private let messages: [String]
    private var tailLatch = TranscriptTailPinLatch()

    init(messages: [String]) {
        self.messages = messages
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let open = TranscriptScrollPolicy.openAction(
            unreadAnchorId: nil,
            unreadCountAtOpen: 0,
            unreadAnchorAbandoned: false
        )
        _ = open // host scrolls to live edge or unread divider from here

        tailLatch.tailVisible(itemCount: messages.count, tailID: messages.last)
    }
}
