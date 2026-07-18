//
// SNTranscriptDaySectionTests.swift
// bitchatTests
//
// Pins the Phase 3 collection-host structure: day sections (pinned sticky
// headers) built from message dates, and the width-scoped pre-measured row
// height cache that makes contentSize exact before layout.
//

import Foundation
import Testing
import TranscriptEngine
@testable import Sonar

struct SNTranscriptDaySectionTests {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    @Test
    func groupsMessagesIntoOneSectionPerLocalDay() {
        let cal = utc
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day1Later = day1.addingTimeInterval(3_600)
        let day2 = day1.addingTimeInterval(86_400)
        let now = day2.addingTimeInterval(7_200)

        let sections = snTranscriptDaySections(
            entries: [
                ("a", day1),
                ("b", day1Later),
                ("c", day2),
            ],
            unreadAnchorId: nil,
            calendar: cal,
            now: now
        )
        #expect(sections.count == 2)
        #expect(sections[0].rows == [.message("a"), .message("b")])
        #expect(sections[1].rows == [.message("c")])
        #expect(sections[0].dayKey != sections[1].dayKey)
        #expect(!sections[0].label.isEmpty)
    }

    @Test
    func undatedLeadingRowsGetHeaderlessSectionAndLaterUndatedInherit() {
        let cal = utc
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let sections = snTranscriptDaySections(
            entries: [
                ("pre1", nil),
                ("pre2", nil),
                ("a", day1),
                ("mid", nil),
            ],
            unreadAnchorId: nil,
            calendar: cal
        )
        #expect(sections.count == 2)
        #expect(sections[0].dayKey == "")
        #expect(sections[0].label == "")
        #expect(sections[0].rows == [.message("pre1"), .message("pre2")])
        // Undated row after a dated one inherits the running day section.
        #expect(sections[1].rows == [.message("a"), .message("mid")])
    }

    @Test
    func unreadDividerLandsBeforeItsAnchorRow() {
        let cal = utc
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let sections = snTranscriptDaySections(
            entries: [
                ("a", day1),
                ("b", day1.addingTimeInterval(60)),
                ("c", day1.addingTimeInterval(120)),
            ],
            unreadAnchorId: "b",
            calendar: cal
        )
        #expect(sections.count == 1)
        #expect(sections[0].rows == [
            .message("a"), .unreadDivider, .message("b"), .message("c"),
        ])
    }

    @Test
    func duplicateMessageIDsAreDropped() {
        let cal = utc
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let sections = snTranscriptDaySections(
            entries: [
                ("a", day1),
                ("a", day1.addingTimeInterval(60)),
                ("b", day1.addingTimeInterval(120)),
            ],
            unreadAnchorId: nil,
            calendar: cal
        )
        let all = sections.flatMap(\.rows)
        #expect(all == [.message("a"), .message("b")])
    }

    @Test
    func revisitedDayKeepsUniqueSectionIdentity() {
        // Out-of-order feeds must never produce duplicate diffable sections.
        let cal = utc
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let sections = snTranscriptDaySections(
            entries: [
                ("a", day1),
                ("b", day2),
                ("c", day1),
            ],
            unreadAnchorId: nil,
            calendar: cal
        )
        #expect(sections.count == 3)
        let keys = sections.map(\.dayKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test
    func heightCacheMeasuresOncePerKeyAndInvalidatesOnWidthChange() {
        let cache = SNTranscriptRowHeightCache()
        cache.updateWidth(390)

        var measures = 0
        let h1 = cache.height(forKey: "m|1") { measures += 1; return 44 }
        let h2 = cache.height(forKey: "m|1") { measures += 1; return 99 }
        #expect(h1 == 44)
        #expect(h2 == 44) // cached — second measure closure not consulted
        #expect(measures == 1)

        // A different key (e.g. expanded bit flipped) re-measures.
        _ = cache.height(forKey: "m|1|expanded") { measures += 1; return 120 }
        #expect(measures == 2)

        // Width change wipes every cached height.
        #expect(cache.updateWidth(320))
        #expect(cache.count == 0)
        _ = cache.height(forKey: "m|1") { measures += 1; return 40 }
        #expect(measures == 3)

        // Same width again is a no-op.
        #expect(!cache.updateWidth(320))
        #expect(cache.count == 1)
    }
}
