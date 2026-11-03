import Foundation

/// Parses the text printed by `claude -p /usage`, for example:
///
///     Current session: 1% used · resets Nov 3 at 2:30pm (Europe/Zurich)
///     Current week (all models): 9% used · resets Nov 8 at 9am (Europe/Zurich)
///     Current week (Fable): 0% used · resets Nov 8 at 9am (Europe/Zurich)
///
/// The format is human-oriented, so every line is matched strictly. Lines that
/// do not match are ignored rather than guessed at.
enum ClaudeUsageParser {
    static func quota(from text: String, now: Date = Date()) -> QuotaSnapshot? {
        let windows = text
            .components(separatedBy: .newlines)
            .compactMap { window(from: $0.trimmingCharacters(in: .whitespaces), now: now) }
        return windows.isEmpty ? nil : QuotaSnapshot(windows: windows)
    }

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^Current (session|week)(?: \(([^)]*)\))?:\s*(\d+(?:\.\d+)?)%\s+used(?:\s*[·•-]\s*resets\s+(.+?))?\s*$"#,
        options: [.caseInsensitive]
    )

    private static let resetPattern = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:,\s*(\d{4}))?\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#,
        options: [.caseInsensitive]
    )

    private static let timeZonePattern = try! NSRegularExpression(pattern: #"\s*\(([^()]+)\)\s*$"#)

    static func window(from line: String, now: Date) -> QuotaWindow? {
        guard let match = linePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let scope = group(1, match, line)?.lowercased(),
              let percentText = group(3, match, line),
              let percent = Double(percentText) else { return nil }

        let qualifier = group(2, match, line)
        let resetsAt = group(4, match, line).flatMap { resetDate(from: $0, now: now) }
        let used = Int(percent.rounded())

        if scope == "session" {
            return QuotaWindow(kind: .session, label: "5h", usedPercent: used, resetsAt: resetsAt, windowDurationMinutes: 300)
        }
        if let qualifier, qualifier.lowercased() != "all models" {
            return QuotaWindow(kind: .weeklyModel, label: qualifier, usedPercent: used, resetsAt: resetsAt, windowDurationMinutes: 10_080)
        }
        return QuotaWindow(kind: .weekly, label: "Week", usedPercent: used, resetsAt: resetsAt, windowDurationMinutes: 10_080)
    }

    static func resetDate(from text: String, now: Date) -> Date? {
        var remainder = text.trimmingCharacters(in: .whitespaces)
        var timeZone = TimeZone.current
        if let match = timeZonePattern.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
           let identifier = group(1, match, remainder),
           let range = Range(match.range, in: remainder) {
            timeZone = TimeZone(identifier: identifier) ?? TimeZone(abbreviation: identifier) ?? timeZone
            remainder.removeSubrange(range)
        }

        guard let match = resetPattern.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
              var hour = group(4, match, remainder).flatMap(Int.init) else { return nil }
        let minute = group(5, match, remainder).flatMap(Int.init) ?? 0
        switch group(6, match, remainder)?.lowercased() {
        case "pm" where hour < 12: hour += 12
        case "am" where hour == 12: hour = 0
        default: break
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute

        if let monthName = group(1, match, remainder) {
            guard let month = monthNumber(monthName),
                  let day = group(2, match, remainder).flatMap(Int.init) else { return nil }
            components.month = month
            components.day = day
            let explicitYear = group(3, match, remainder).flatMap(Int.init)
            if let explicitYear { components.year = explicitYear }
            guard var date = calendar.date(from: components) else { return nil }
            // "Jan 2" printed in late December refers to next year.
            if explicitYear == nil, date < now.addingTimeInterval(-86_400),
               let next = calendar.date(byAdding: .year, value: 1, to: date) {
                date = next
            }
            return date
        }

        guard var date = calendar.date(from: components) else { return nil }
        if date < now, let next = calendar.date(byAdding: .day, value: 1, to: date) { date = next }
        return date
    }

    private static func monthNumber(_ name: String) -> Int? {
        let prefix = name.prefix(3).lowercased()
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.firstIndex(of: prefix).map { $0 + 1 }
    }

    private static func group(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
