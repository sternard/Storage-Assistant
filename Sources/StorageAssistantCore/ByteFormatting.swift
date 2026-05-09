import Foundation

public enum StorageFormatting {
    public static func bytes(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: byteCount)
    }

    public static func daysSince(_ date: Date?, now: Date = Date()) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: now).day
    }

    public static func agePhrase(for date: Date?, now: Date = Date()) -> String {
        guard let days = daysSince(date, now: now) else {
            return "age unknown"
        }

        if days < 1 {
            return "today"
        }

        if days == 1 {
            return "1 day ago"
        }

        if days < 30 {
            return "\(days) days ago"
        }

        let months = max(1, days / 30)
        if months < 12 {
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }

        let years = max(1, days / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }
}
