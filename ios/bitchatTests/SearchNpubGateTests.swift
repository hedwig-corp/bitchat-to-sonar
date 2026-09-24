import Testing
@testable import Sonar

/// QA-A18: any `npub1` prefix raised "Start secure chat" mid-typing, which can
/// only fail for a partial key. The search sheet and the macOS command palette
/// share `MarmotService.isCompleteNpub`.
struct SearchNpubGateTests {
    private let full = "npub1pqm5mzn6ph0ldzd2ldflq9g9xv25yc5tqrzkyll042mggs40p5fsh2d6mz"

    @Test
    func completeNpubStartsAChat() {
        #expect(MarmotService.isCompleteNpub(full))
        #expect(MarmotService.isCompleteNpub("  \(full.uppercased())  "))
    }

    @Test
    func partialNpubDoesNot() {
        #expect(!MarmotService.isCompleteNpub("npub1pqm5"))
        #expect(!MarmotService.isCompleteNpub(String(full.dropLast())))
        #expect(!MarmotService.isCompleteNpub(full + "q"))
    }

    @Test
    func nonBech32CharactersAreRejected() {
        let wrongChar = String(full.dropLast()) + "b"
        let wrongPrefix = "nsec1" + String(full.dropFirst(5))
        #expect(!MarmotService.isCompleteNpub(wrongChar))
        #expect(!MarmotService.isCompleteNpub(wrongPrefix))
    }
}
