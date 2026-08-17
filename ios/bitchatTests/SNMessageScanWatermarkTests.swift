//
// SNMessageScanWatermarkTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct SNMessageScanWatermarkTests {
    private func m(_ secs: Int64, _ count: Int64 = 1) -> SNScanMark {
        SNScanMark(secs: secs, count: count)
    }

    @Test
    func unchangedMarksNeedNoScan() {
        let latest = ["a": m(10), "b": m(20)]
        let watermark = latest
        #expect(snChatsNeedingMessageScan(latestByChat: latest, scannedWatermark: watermark).isEmpty)
    }

    @Test
    func laterTimestampNeedsScan() {
        let latest = ["a": m(10), "b": m(30)]
        let watermark = ["a": m(10), "b": m(20)]
        #expect(snChatsNeedingMessageScan(latestByChat: latest, scannedWatermark: watermark) == ["b"])
    }

    @Test
    func sameSecondHigherCountNeedsScan() {
        let latest = ["a": m(10, 3)]
        let watermark = ["a": m(10, 2)]
        #expect(snChatsNeedingMessageScan(latestByChat: latest, scannedWatermark: watermark) == ["a"])
    }

    @Test
    func sameSecondSameCountIsStable() {
        let latest = ["a": m(10, 2)]
        let watermark = ["a": m(10, 2)]
        #expect(snChatsNeedingMessageScan(latestByChat: latest, scannedWatermark: watermark).isEmpty)
    }

    @Test
    func unseenChatNeedsScan() {
        let latest = ["new": m(5)]
        let watermark: [String: SNScanMark] = [:]
        #expect(snChatsNeedingMessageScan(latestByChat: latest, scannedWatermark: watermark) == ["new"])
    }

    @Test
    func emptyPageStillTrackedAsUnseenUntilWatermarked() {
        let latest = ["empty": snScanMark(messageCount: 0, latestDate: nil)]
        let watermark: [String: SNScanMark] = [:]
        #expect(snChatsNeedingMessageScan(latestByChat: latest, scannedWatermark: watermark) == ["empty"])
    }

    @Test
    func stagedPageForcesRescanEvenWhenWatermarkMatches() {
        let latest = ["chat": m(10)]
        let watermark = ["chat": m(10)]
        #expect(
            snChatsNeedingMessageScan(
                latestByChat: latest,
                scannedWatermark: watermark,
                stagedPageChatIds: ["chat", "missing"]
            ) == ["chat"]
        )
    }

    @Test
    func scanMarkUsesLatestDateSeconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let mark = snScanMark(messageCount: 4, latestDate: date)
        #expect(mark.secs == 1_700_000_000)
        #expect(mark.count == 4)
    }
}
