import Foundation

/// Whether to insert a day chip before `current` given the previous row's date.
public func transcriptShowsDayChip(previous: Date?, current: Date?, calendar: Calendar = .current) -> Bool {
    guard let current else { return false }
    guard let previous else { return true }
    return !calendar.isDate(previous, inSameDayAs: current)
}

private let transcriptWeekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE"
    return f
}()

private let transcriptShortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM"
    return f
}()

/// Today / Yesterday / weekday / `d MMM` — matches Compose `dayLabel`.
public func transcriptDayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let start = calendar.startOfDay(for: date)
    let todayStart = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: start, to: todayStart).day ?? Int.max
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days > 0, days < 7 {
        return transcriptWeekdayFormatter.string(from: date)
    }
    return transcriptShortDateFormatter.string(from: date)
}
