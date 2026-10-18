// Dates, times and amounts as the menu, the alerts and the windows write them.

import Foundation

/// Where Octopus, National Grid and Elexon all keep their clocks, and the fallback for anything
/// that doesn't say.
let londonTimeZone = TimeZone(identifier: "Europe/London")!

func calendar(_ tz: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal
}

/// DateFormatter is costly to build and a menu rebuild formats a dozen dates, so keep one per
/// format and timezone. Formatting itself is thread-safe; the lock only guards the dictionary.
private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]

    func formatter(_ format: String, _ tz: TimeZone) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(format)|\(tz.identifier)"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = tz
        f.dateFormat = format
        cache[key] = f
        return f
    }
}

private let formatters = FormatterCache()

func formatted(_ date: Date, _ format: String, _ tz: TimeZone) -> String {
    formatters.formatter(format, tz).string(from: date)
}

func dayLabel(_ date: Date, now: Date, _ tz: TimeZone) -> String {
    let cal = calendar(tz)
    if cal.isDate(date, inSameDayAs: now) { return "Today" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        return "Tomorrow"
    }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday"
    }
    return formatted(date, "EEE", tz)
}

func stamp(_ date: Date, now: Date, _ tz: TimeZone) -> String {
    "\(dayLabel(date, now: now, tz)) \(formatted(date, "HH:mm", tz))"
}

func pence(_ v: Double) -> String { String(format: "%.2fp/kWh", v) }

/// Power as it reads best: whole watts below a kilowatt, kilowatts to one place from there. Rounded
/// first, so 999.6 W reads "1.0 kW" rather than "1000 W". The sign is the caller's to word.
func powerText(_ watts: Double) -> String {
    let w = abs(watts).rounded()
    return w < 1000 ? String(format: "%.0f W", w) : String(format: "%.1f kW", w / 1000)
}

func money(_ pence: Int) -> String { String(format: "£%.2f", Double(abs(pence)) / 100) }

/// Octopus states a balance as positive when you are in credit, so the sign carries the meaning
/// and has to be spelled out rather than shown as a minus.
func balanceText(_ pence: Int) -> String {
    "\(money(pence)) \(pence < 0 ? "owed" : "in credit")"
}

func clockTime(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

/// Whole days between two dates by the local calendar, so "tomorrow" is tomorrow whatever the
/// time of day. Counting in 24-hour blocks would call tomorrow morning "today" this evening.
func daysUntil(_ date: Date, now: Date, _ tz: TimeZone) -> Int {
    let cal = calendar(tz)
    return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
}

/// Reads after a verb: "ends today", "ends tomorrow", "ends in 14 days".
func dayCount(_ days: Int) -> String {
    switch days {
    case ...0: return "today"
    case 1: return "tomorrow"
    default: return "in \(days) days"
    }
}
