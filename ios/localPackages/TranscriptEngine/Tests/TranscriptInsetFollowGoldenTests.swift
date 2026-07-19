import Foundation
import Testing
@testable import TranscriptEngine

struct TranscriptInsetFollowGoldenTests {

    struct GoldenCase: Decodable {
        struct Input: Decodable {
            let wasAtTail: Bool
            let userScrolling: Bool
            let isPrepending: Bool
        }

        let name: String
        let input: Input
        let expected: String
    }

    private struct GoldenFile: Decodable {
        let cases: [GoldenCase]
    }

    private static let goldenCases: [GoldenCase] = {
        let url = Bundle.module.url(forResource: "inset-follow", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(GoldenFile.self, from: data).cases
    }()

    private func expectedDecision(from raw: String) -> TranscriptInsetDecision {
        switch raw {
        case "Pin": return .pin
        case "Lockstep": return .lockstep
        case "Ignore": return .ignore
        default:
            Issue.record("Unknown golden expected: \(raw)")
            return .ignore
        }
    }

    @Test(arguments: goldenCases)
    func insetFollowMatchesGolden(_ golden: GoldenCase) {
        let decision = TranscriptScrollPolicy.insetFollowDecision(
            wasAtTail: golden.input.wasAtTail,
            userScrolling: golden.input.userScrolling,
            isPrepending: golden.input.isPrepending
        )
        #expect(decision == expectedDecision(from: golden.expected), "case \(golden.name)")
    }
}
