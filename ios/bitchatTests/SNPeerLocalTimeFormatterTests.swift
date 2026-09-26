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

        // ICU (iOS 17+) puts a narrow no-break space (U+202F) before "AM";
        // compare the words, not the exact space character.
        let time = display?.timeText.replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(time == "5:00 AM")
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

    @Test
    func offNoteSaysWhetherTheChatOverridesTheDefault() {
        // U1 (#607 QA): with the Settings default off and no per-chat override
        // the note claimed "overrides your Settings default".
        let following = snShareLocalTimeNote(sharing: false, overridden: false, zone: "Europe/Zurich", peerName: "Ana")
        let overridden = snShareLocalTimeNote(sharing: false, overridden: true, zone: "Europe/Zurich", peerName: "Ana")
        let sharing = snShareLocalTimeNote(sharing: true, overridden: false, zone: "Europe/Zurich", peerName: "Ana")
        #expect(following.hasPrefix("Off — follows your Settings default."))
        #expect(!following.contains("overrides"))
        #expect(overridden.hasPrefix("Off for this chat — overrides your Settings default."))
        #expect(sharing.hasPrefix("Sharing Europe/Zurich with Ana inside this chat’s encryption."))
    }

    @Test
    func mixedOffsetUsesCompactDesignCopy() {
        let utc = TimeZone(identifier: "UTC")!
        let display = SNPeerLocalTimeFormatter.display(
            zoneIdentifier: "Asia/Kolkata",
            at: Date(timeIntervalSince1970: 1_768_478_400),
            viewerTimeZone: utc,
            locale: enUS,
            includeRelative: true
        )
        #expect(display?.relativeText == "5h 30m ahead")
        #expect(SNPeerLocalTimeFormatter.relativeAmount(minutes: 45, locale: enUS) == "0h 45m")
        #expect(SNPeerLocalTimeFormatter.relativeAmount(minutes: 60, locale: enUS) == "1 hour")
    }
}
