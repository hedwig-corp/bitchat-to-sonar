//
// SNTranscriptDayChipTests.swift
// bitchatTests
//
// Pins transcript day chips to real calendar days (not a hardcoded "Today"
// at the top of every chat window).
//

import Foundation
import Testing
@testable import Sonar

struct SNTranscriptDayChipTests {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    @Test
    func showsChipOnFirstRowAndWhenDayFlips() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000) // fixed epoch
        let sameDay = day1.addingTimeInterval(3600)
        let nextDay = day1.addingTimeInterval(86_400)
        #expect(snTranscriptShowsDayChip(previous: nil, current: day1, calendar: utc))
        #expect(!snTranscriptShowsDayChip(previous: day1, current: sameDay, calendar: utc))
        #expect(snTranscriptShowsDayChip(previous: day1, current: nextDay, calendar: utc))
        #expect(!snTranscriptShowsDayChip(previous: day1, current: nil, calendar: utc))
    }

    @Test
    func dayLabelUsesTodayYesterdayWeekdayOrDate() {
        let now = Date(timeIntervalSince1970: 1_720_000_000) // ~2024-07-03 UTC
        let cal = utc
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: today)!
        let twoWeeksAgo = cal.date(byAdding: .day, value: -14, to: today)!

        #expect(snTranscriptDayLabel(for: today, now: now, calendar: cal) == "Today")
        #expect(snTranscriptDayLabel(for: yesterday, now: now, calendar: cal) == "Yesterday")
        let weekday = snTranscriptDayLabel(for: threeDaysAgo, now: now, calendar: cal)
        #expect(weekday != "Today")
        #expect(weekday != "Yesterday")
        #expect(weekday.count == 3) // EEE
        let older = snTranscriptDayLabel(for: twoWeeksAgo, now: now, calendar: cal)
        #expect(older.contains(" ")) // "d MMM"
        #expect(older != "Today")
    }
}
