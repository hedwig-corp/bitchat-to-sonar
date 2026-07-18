import Foundation
import Testing
@testable import TranscriptEngine

struct TranscriptDaySectionTests {

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

        let sections = transcriptDaySections(
            entries: [
                ("a", day1),
                ("b", day1Later),
                ("c", day2),
            ],
            unreadAnchorId: nil,
            calendar: cal,
            now: day2.addingTimeInterval(7_200)
        )
        #expect(sections.count == 2)
        #expect(sections[0].rows == [.message("a"), .message("b")])
        #expect(sections[1].rows == [.message("c")])
    }

    @Test
    func heightCacheMeasuresOncePerKeyAndInvalidatesOnWidthChange() {
        let cache = TranscriptRowHeightCache()
        cache.updateWidth(390)

        var measures = 0
        let h1 = cache.height(forKey: "m|1") { measures += 1; return 44 }
        let h2 = cache.height(forKey: "m|1") { measures += 1; return 99 }
        #expect(h1 == 44)
        #expect(h2 == 44)
        #expect(measures == 1)

        #expect(cache.updateWidth(320))
        _ = cache.height(forKey: "m|1") { measures += 1; return 40 }
        #expect(measures == 2)
    }
}
