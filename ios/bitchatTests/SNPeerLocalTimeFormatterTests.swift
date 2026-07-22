import Foundation
import Testing
@testable import Sonar

struct SNPeerLocalTimeFormatterTests {
    private let enUS = Locale(identifier: "en_US")
    private let newYork = TimeZone(identifier: "America/New_York")!

    @Test
    func formatsViewerClockPreferenceAndRelativeOffset() {
        let winter = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00Z
        let display = SNPeerLocalTimeFormatter.display(
            zoneIdentifier: "America/Phoenix",
            at: winter,
            viewerTimeZone: newYork,
            locale: enUS,
            includeRelative: true
        )

        #expect(display?.timeText == "5:00 AM")
        #expect(display?.relativeText == "2 hours behind")
    }

    @Test
    func recalculatesDstFromZoneIdentifierWithoutReshare() {
        let winter = Date(timeIntervalSince1970: 1_768_478_400) // 2026-01-15 12:00Z
        let summer = Date(timeIntervalSince1970: 1_784_116_800) // 2026-07-15 12:00Z

        let winterText = SNPeerLocalTimeFormatter.display(
            zoneIdentifier: "America/Phoenix",
            at: winter,
            viewerTimeZone: newYork,
            locale: enUS,
            includeRelative: true
        )?.relativeText
        let summerText = SNPeerLocalTimeFormatter.display(
            zoneIdentifier: "America/Phoenix",
            at: summer,
            viewerTimeZone: newYork,
            locale: enUS,
            includeRelative: true
        )?.relativeText

        #expect(winterText == "2 hours behind")
        #expect(summerText == "3 hours behind")
    }

    @Test
    func invalidPlatformTimezoneNeverRenders() {
        #expect(
            SNPeerLocalTimeFormatter.display(
                zoneIdentifier: "Mars/Olympus_Mons",
                includeRelative: true
            ) == nil
        )
    }
}
