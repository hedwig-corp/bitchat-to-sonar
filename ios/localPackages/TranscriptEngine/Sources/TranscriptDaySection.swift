import Foundation

public enum TranscriptDayRow: Hashable {
    case unreadDivider
    case message(String)
}

public struct TranscriptDaySection: Hashable {
    public let dayKey: String
    public let label: String
    public var rows: [TranscriptDayRow]

    public init(dayKey: String, label: String, rows: [TranscriptDayRow]) {
        self.dayKey = dayKey
        self.label = label
        self.rows = rows
    }
}

public func transcriptDaySections(
    entries: [(id: String, date: Date?)],
    unreadAnchorId: String?,
    calendar: Calendar = .current,
    now: Date = Date()
) -> [TranscriptDaySection] {
    var sections: [TranscriptDaySection] = []
    var seenIDs = Set<String>()
    var usedDayKeys = Set<String>()
    var previousDay: Date?
    for entry in entries {
        let opensNewSection = sections.isEmpty
            || transcriptShowsDayChip(previous: previousDay, current: entry.date, calendar: calendar)
        if opensNewSection {
            var dayKey = ""
            var label = ""
            if let date = entry.date {
                dayKey = String(Int(calendar.startOfDay(for: date).timeIntervalSince1970))
                label = transcriptDayLabel(for: date, now: now, calendar: calendar)
            }
            var unique = dayKey
            var bump = 1
            while !usedDayKeys.insert(unique).inserted {
                unique = "\(dayKey)#\(bump)"
                bump += 1
            }
            sections.append(TranscriptDaySection(dayKey: unique, label: label, rows: []))
        }
        previousDay = entry.date ?? previousDay
        guard seenIDs.insert(entry.id).inserted else { continue }
        if entry.id == unreadAnchorId {
            sections[sections.count - 1].rows.append(.unreadDivider)
        }
        sections[sections.count - 1].rows.append(.message(entry.id))
    }
    return sections
}
