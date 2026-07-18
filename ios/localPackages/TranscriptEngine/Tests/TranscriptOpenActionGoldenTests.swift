import Foundation
import Testing
@testable import TranscriptEngine

struct TranscriptOpenActionGoldenTests {

    struct GoldenCase: Decodable {
        struct Input: Decodable {
            let unreadAnchorId: String?
            let unreadCountAtOpen: UInt64?
            let unreadAnchorAbandoned: Bool
            let jumpMessageId: String?
        }

        let name: String
        let input: Input
        let expected: String
    }

    private struct GoldenFile: Decodable {
        let cases: [GoldenCase]
    }

    private static let goldenCases: [GoldenCase] = {
        let url = Bundle.module.url(forResource: "open-action", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(GoldenFile.self, from: data).cases
    }()

    private func expectedAction(from raw: String) -> TranscriptOpenAction {
        if raw == "LiveEdge" { return .liveEdge }
        if raw == "UnreadDivider" { return .unreadDivider }
        if raw.hasPrefix("{") {
            // {"Jump":"m:search"}
            let id = raw
                .replacingOccurrences(of: "{\"Jump\":\"", with: "")
                .replacingOccurrences(of: "\"}", with: "")
            return .jump(id: id)
        }
        Issue.record("Unknown golden expected: \(raw)")
        return .liveEdge
    }

    @Test(arguments: goldenCases)
    func openActionMatchesGolden(_ golden: GoldenCase) {
        let action = TranscriptScrollPolicy.openAction(
            unreadAnchorId: golden.input.unreadAnchorId,
            unreadCountAtOpen: golden.input.unreadCountAtOpen,
            unreadAnchorAbandoned: golden.input.unreadAnchorAbandoned,
            jumpId: golden.input.jumpMessageId
        )
        #expect(action == expectedAction(from: golden.expected), "case \(golden.name)")
    }
}
