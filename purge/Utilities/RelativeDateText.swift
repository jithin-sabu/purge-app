import Foundation

func relativeDateText(for date: Date, referenceDate: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: referenceDate) {
        return "Today"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate),
       calendar.isDate(date, inSameDayAs: tomorrow) {
        return "Tomorrow"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday"
    }

    let relative = relativeDateFormatter.localizedString(for: date, relativeTo: referenceDate)
    guard let first = relative.first else { return relative }
    return first.uppercased() + String(relative.dropFirst())
}

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.formattingContext = .beginningOfSentence
    return formatter
}()

/// "just now", "40s ago", "5m ago", "3h ago", "2d ago": the menu bar's and the
/// Overview's short form for when a scan finished.
func compactAgoText(from date: Date, to now: Date) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 10 { return "just now" }
    if seconds < 60 { return "\(Int(seconds / 10) * 10)s ago" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return "\(hours / 24)d ago"
}
