//
// SonarNoteToSelfTests.swift
// bitchatTests
//
import Foundation
import Testing
@testable import Sonar

/// Note to Self sits at the top of Messages on both apps (Compose:
/// `NoteToSelfTest`). iOS sorts every row by recency first, so without the pin
/// a quiet Note to Self sinks under any chat with newer traffic.
@MainActor
struct SonarNoteToSelfTests {
    private func row(_ id: String, title: String, at seconds: TimeInterval, groupId: String?) -> SNDMRow {
        SNDMRow(
            id: id, title: title, preview: "", time: "", unread: false,
            presence: false, verified: false, isMarmot: groupId != nil,
            lastDate: Date(timeIntervalSince1970: seconds), marmotGroupId: groupId
        )
    }

    @Test
    func noteToSelfTopsTheListEvenWhenOlder() {
        let rows = snSortDMRowsByRecency([
            row("marmot:n0te", title: "Note to Self", at: 100, groupId: "n0te"),
            row("marmot:giulia", title: "Giulia", at: 300, groupId: "giulia"),
            row("sara", title: "Sara", at: 200, groupId: nil),
        ])
        // The premise: recency alone puts Note to Self last.
        #expect(rows.last?.id == "marmot:n0te")
        let pinned = snPinNoteToSelfFirst(rows, noteToSelfGroupId: "n0te")
        #expect(pinned.map(\.id) == ["marmot:n0te", "marmot:giulia", "sara"])
    }

    @Test
    func aGroupSomeoneNamedNoteToSelfIsNotPinned() {
        let rows = snSortDMRowsByRecency([
            row("marmot:impostor", title: "Note to Self", at: 100, groupId: "impostor"),
            row("marmot:giulia", title: "Giulia", at: 300, groupId: "giulia"),
        ])
        let pinned = snPinNoteToSelfFirst(rows, noteToSelfGroupId: "n0te")
        #expect(pinned.map(\.id) == ["marmot:giulia", "marmot:impostor"])
    }

    @Test
    func beforeEnsureAnswersNothingMoves() {
        let rows = [
            row("marmot:giulia", title: "Giulia", at: 300, groupId: "giulia"),
            row("sara", title: "Sara", at: 200, groupId: nil),
        ]
        #expect(snPinNoteToSelfFirst(rows, noteToSelfGroupId: nil).map(\.id) == rows.map(\.id))
    }
}
