//
// BackupFormat.swift
// bitchat
//
// Swift mirror of apps/sonar/.../BackupFormat.kt. The Settings "Data & storage"
// rows and the Chat backup stats strip render through this on both platforms,
// and the design shows the figures side by side — a rounding or wording
// difference between iOS and Android would read as a bug, not a nuance.
//
// Keep the two files in step: same thresholds, same units, same strings.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum BackupFormat {

    /// Human size, matching the design's "124 MB" shape.
    ///
    /// Decimal (1000-based), not binary: this number sits next to the OS storage
    /// settings the user just came from, and those are decimal on both
    /// platforms. Returns nil for an unmeasured value so callers render a dash
    /// rather than a confident "0 B".
    static func bytes(_ value: UInt64?) -> String? {
        guard let v = value else { return nil }
        if v < 1_000 { return "\(v) B" }
        let units = ["kB", "MB", "GB", "TB"]
        var size = Double(v) / 1_000.0
        var unit = 0
        while size >= 1_000.0 && unit < units.count - 1 {
            size /= 1_000.0
            unit += 1
        }
        // One decimal below 10 so "1.2 MB" does not collapse to "1 MB"; whole
        // numbers above, where the extra digit is noise.
        if size < 10.0 {
            let tenths = Int((size * 10).rounded())
            return "\(tenths / 10).\(tenths % 10) \(units[unit])"
        }
        return "\(Int(size.rounded())) \(units[unit])"
    }

    /// Grouped count for the stats strip ("1,204").
    static func count(_ value: UInt64?) -> String? {
        guard let v = value else { return nil }
        let digits = String(v)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }

    /// "Today, 04:12" / "Yesterday, 22:40" / "3 d ago" for the last-backup row.
    ///
    /// `now` is injected so this stays pure and testable — a helper that read the
    /// clock itself could not be pinned.
    static func lastBackup(
        atSecs: UInt64?,
        nowSecs: UInt64,
        offsetSecs: Int64 = Int64(TimeZone.current.secondsFromGMT())
    ) -> String? {
        guard let at = atSecs, at > 0 else { return nil }
        // A backup stamped in the future is clock skew, not a negative duration.
        if at >= nowSecs { return "Just now" }
        let ago = nowSecs - at
        if ago < 60 { return "Just now" }
        let localAt = Int64(at) + offsetSecs
        let localNow = Int64(nowSecs) + offsetSecs
        let dayAt = localAt / 86_400
        let dayNow = localNow / 86_400
        let clock = clockOf(localAt)
        if dayAt == dayNow { return "Today, \(clock)" }
        if dayNow - dayAt == 1 { return "Yesterday, \(clock)" }
        return "\(ago / 86_400) d ago"
    }

    private static func clockOf(_ epochSecs: Int64) -> String {
        let secondsOfDay = ((epochSecs % 86_400) + 86_400) % 86_400
        let h = secondsOfDay / 3600
        let m = (secondsOfDay % 3600) / 60
        return String(format: "%02d:%02d", h, m)
    }

    /// Settings label for the core cadence values.
    static func frequencyLabel(_ frequency: String) -> String {
        switch frequency {
        case "manual": return "Manual only"
        case "weekly": return "Weekly"
        default: return "Daily"
        }
    }
}
