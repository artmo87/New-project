import Foundation

/// Shared, cached formatters so every screen shows times, dates and sizes the same way.
enum Formatters {

    // MARK: - Cached formatter instances

    private static let shortDateSameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let shortDateOtherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    // MARK: - Durations

    /// "mm:ss" for anything under an hour, "h:mm:ss" from one hour on. Never crashes on
    /// NaN, infinity or negative input (shows "00:00").
    static func clock(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(twoDigits(minutes)):\(twoDigits(secs))"
    }

    /// Human-friendly length: "45 s", "48 min", "1 h 05 min".
    static func durationWords(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        if total < 60 {
            return "\(total) s"
        }
        let totalMinutes = Int((Double(total) / 60.0).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours) h \(twoDigits(minutes)) min"
    }

    // MARK: - Dates

    /// "Oct 1" for dates in the current year, "Oct 1, 2025" otherwise.
    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let dateYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        if dateYear == currentYear {
            return shortDateSameYearFormatter.string(from: date)
        }
        return shortDateOtherYearFormatter.string(from: date)
    }

    /// "Oct 1, 2026 at 3:15 PM" (localized).
    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// "Just now", "5 minutes ago", "yesterday", "2 days ago" (localized).
    static func relative(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval.isNaN || abs(interval) < 60 {
            return "Just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Sizes

    /// "1.2 MB", "356 KB" (localized). Negative values are shown as zero.
    static func fileSize(_ bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: max(0, bytes))
    }

    // MARK: - Private helpers

    /// Whole seconds, clamped to a sane range so integer conversion can never trap.
    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let maximum: TimeInterval = 359_999 // just under 100 hours
        return Int(min(seconds, maximum).rounded(.down))
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
