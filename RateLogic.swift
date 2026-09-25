// Rate logic: pure functions over a Snapshot, so they can be tested without the network.

import Foundation

func calendar(_ tz: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal
}

/// Cheap intervals that haven't ended yet and start within the next 48 hours, merged and sorted.
func cheapIntervals(_ s: Snapshot, now: Date) -> [Interval] {
    guard s.hasCheapRate else { return [] }
    let cal = calendar(s.tz)
    let today = cal.startOfDay(for: now)
    var all: [Interval] = []
    for offset in -1...2 {
        guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
        for w in s.windows {
            let endDay = w.to <= w.from ? cal.date(byAdding: .day, value: 1, to: day) ?? day : day
            guard
                let start = cal.date(bySettingHour: w.from / 60, minute: w.from % 60, second: 0, of: day),
                let end = cal.date(bySettingHour: w.to / 60, minute: w.to % 60, second: 0, of: endDay)
            else { continue }
            all.append(Interval(start: start, end: end, smart: false))
        }
    }
    all += s.dispatches
    let horizon = now.addingTimeInterval(48 * 3600)
    all = all.filter { $0.end > now && $0.start < horizon }.sorted { $0.start < $1.start }

    var merged: [Interval] = []
    for i in all {
        if var last = merged.last, i.start <= last.end {
            last.end = max(last.end, i.end)
            last.smart = last.smart && i.smart
            merged[merged.count - 1] = last
        } else {
            merged.append(i)
        }
    }
    return merged
}

/// The next switch between rates, whichever way it goes.
struct RateChange: Equatable {
    var at: Date
    /// True when the cheap rate is starting, false when it is ending.
    var toCheap: Bool
}

/// When the rate next changes. Inside a cheap window that is its end; outside one it is the start
/// of the next. `intervals` are the merged cheap windows, so back-to-back slots are one window and
/// do not produce a change where nothing actually changes.
func nextRateChange(_ intervals: [Interval], now: Date) -> RateChange? {
    if let active = currentInterval(intervals, now: now) {
        return RateChange(at: active.end, toCheap: false)
    }
    guard let next = intervals.first(where: { $0.start > now }) else { return nil }
    return RateChange(at: next.start, toCheap: true)
}

func currentInterval(_ intervals: [Interval], now: Date) -> Interval? {
    intervals.first { $0.start <= now && now < $0.end }
}

func isCheap(_ s: Snapshot, now: Date) -> Bool {
    currentInterval(cheapIntervals(s, now: now), now: now) != nil
}

/// Dispatches still to come. Completed ones are history and churn constantly, so they are not
/// part of "the plan".
func futureDispatches(_ s: Snapshot, now: Date) -> [Interval] {
    s.dispatches.filter { $0.end > now }.sorted { $0.start < $1.start }
}

/// What Octopus plans to put into the car, and when.
///
/// The energy is the planner's own arithmetic at a flat assumed rate — see `Interval.plannedKwh` —
/// so this says "about" and stops short of claiming it is what the car will draw. Returns nil when
/// nothing is planned or the plan states no energy.
func plannedChargeLine(_ s: Snapshot, now: Date) -> String? {
    let upcoming = futureDispatches(s, now: now)
    guard !upcoming.isEmpty else { return nil }
    let total = upcoming.compactMap(\.plannedKwh).reduce(0, +)
    guard total > 0 else { return nil }

    let slots = upcoming.prefix(3).map {
        "\(formatted($0.start, "HH:mm", s.tz))–\(formatted($0.end, "HH:mm", s.tz))"
    }
    var when = slots.joined(separator: ", ")
    if upcoming.count > slots.count { when += ", …" }
    // A boost is one you asked for; a smart charge is one Octopus planned. Only worth saying when
    // it isn't the ordinary case.
    let boost = upcoming.contains { ($0.chargeType ?? "SMART").uppercased() == "BOOST" }
    let kind = boost ? "Boost charge" : "Charging"
    return "\(kind) \(when) · about \(String(format: "%.0f", total)) kWh planned"
}

/// A fetch whose device query failed keeps the cars and plan it last knew, rather than dropping
/// them. Otherwise one transient failure blanks the charge windows out of the menu and the icon,
/// and the next good fetch sees a plan appear from nowhere. Known-ness is inherited: with nothing
/// earlier to carry, the result stays unknown and comparisons against it are skipped.
func carryForwardDevices(_ fetched: Snapshot, from previous: Snapshot?, now: Date) -> Snapshot {
    guard !fetched.devicesKnown, let previous else { return fetched }
    var merged = fetched
    merged.cars = previous.cars
    // Only the plan still to come. Completed slots arrive in the same request as the devices, so
    // a failed one lost them too — but once ended they no longer affect any cheap window, and a
    // slot still running is in the plan still to come.
    merged.dispatches += futureDispatches(previous, now: now)
    merged.devicesKnown = previous.devicesKnown
    return merged
}

struct DispatchChange {
    var title: String
    var body: String
}

/// How the charge plan changed, or nil when it is the same plan. Octopus re-plans dispatches by a
/// few minutes constantly, so a slot that merely shifted within `tolerance` is not a change —
/// alerting on that would be noise several times an hour.
func dispatchChange(
    from old: [Interval], to new: [Interval], tz: TimeZone, tolerance: TimeInterval = 5 * 60
) -> DispatchChange? {
    var unmatched = old
    var added: [Interval] = []
    for slot in new {
        let match = unmatched.firstIndex {
            abs($0.start.timeIntervalSince(slot.start)) <= tolerance
                && abs($0.end.timeIntervalSince(slot.end)) <= tolerance
        }
        if let match { unmatched.remove(at: match) } else { added.append(slot) }
    }
    guard !added.isEmpty || !unmatched.isEmpty else { return nil }

    func describe(_ slots: [Interval]) -> String {
        slots.map { "\(formatted($0.start, "HH:mm", tz))–\(formatted($0.end, "HH:mm", tz))" }
            .joined(separator: ", ")
    }
    if new.isEmpty {
        return DispatchChange(title: "Smart charge cancelled", body: "No charge is planned.")
    }
    let plan = "Now planned for \(describe(new))."
    if old.isEmpty {
        return DispatchChange(title: "Smart charge planned", body: plan)
    }
    let title = added.isEmpty ? "Smart charge slot dropped" : "Smart charge plan changed"
    return DispatchChange(title: title, body: plan)
}

/// Decides when a change in the charge plan is announced.
///
/// Octopus re-plans constantly, so a cooldown stops a plan that flaps between two shapes from
/// alerting on every flip. But a cooldown that simply skips the check loses any real change made
/// during it: the next fetch compares against the previous one, which already contains the change.
/// So while the cooldown runs, the comparison point is held at the plan last announced, and the
/// change is announced once the cooldown ends — unless the plan has flapped back by then.
struct DispatchAlertGate {
    var cooldown: TimeInterval = 10 * 60
    var lastAlertAt: Date?
    /// The plan to compare against while an alert is held back.
    var held: [Interval]?

    /// `previous` and `current` are the plans still to come, as `futureDispatches` gives them.
    mutating func check(previous: [Interval], current: [Interval], now: Date, tz: TimeZone) -> DispatchChange? {
        // Slots that have simply finished drop out of the held plan, or their natural end would
        // read as a slot dropped.
        let baseline = held.map { $0.filter { $0.end > now } } ?? previous
        guard let change = dispatchChange(from: baseline, to: current, tz: tz) else {
            // Back where the last announcement left it: a flap that settled. Nothing to hold.
            held = nil
            return nil
        }
        if let lastAlertAt, now.timeIntervalSince(lastAlertAt) < cooldown {
            held = baseline
            return nil
        }
        held = nil
        lastAlertAt = now
        return change
    }
}

/// Domestic energy VAT. Only used to gross up the rare tariff that has no stated rates, since
/// applicableRates quotes prices before tax while everything else on screen includes it.
let vatMultiplier = 1.05

/// How far either side of a rate switch counts as "about to change".
let switchWindow: TimeInterval = 3 * 60

/// Fetch every 5 minutes, or every 30 seconds within `switchWindow` either side of a rate switch.
/// Takes intervals computed with a `switchWindow` lookback, so a switch just gone still counts.
func fetchInterval(_ recent: [Interval], now: Date) -> TimeInterval {
    let nearSwitch = recent.contains {
        abs($0.start.timeIntervalSince(now)) <= switchWindow || abs($0.end.timeIntervalSince(now)) <= switchWindow
    }
    return nearSwitch ? 30 : 300
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

/// How far ahead a tariff ending is worth mentioning at all.
let tariffNoticePeriod = 60

/// The last day the tariff actually applies.
///
/// `validTo` is the instant cover stops, and these contracts stop at midnight — so the raw date is
/// the first day of the *next* tariff, and quoting it would put the end a day late. Stepping back
/// a second lands on the last covered day, and is still correct for an agreement that ends at some
/// other time of day.
func lastCoveredDay(_ ends: Date, _ tz: TimeZone) -> Date {
    calendar(tz).startOfDay(for: ends.addingTimeInterval(-1))
}

/// The end dates worth showing, soonest first.
func endingSoon(_ ends: [TariffEnd], now: Date, tz: TimeZone, within: Int = tariffNoticePeriod) -> [TariffEnd] {
    ends.filter { end in
        guard let ending = end.ends else { return false }  // a variable tariff never ends
        return daysUntil(lastCoveredDay(ending, tz), now: now, tz) <= within
    }
    .sorted { ($0.ends ?? .distantFuture) < ($1.ends ?? .distantFuture) }
}

/// Alert once as each of these is crossed, rather than daily for two months.
let tariffAlertThresholds = [30, 14, 7, 1]

/// The threshold newly crossed, or nil when there is nothing new to say. `alerted` is the
/// tightest threshold already announced for this agreement.
func tariffAlertThreshold(daysLeft: Int, alerted: Int?) -> Int? {
    guard let crossed = tariffAlertThresholds.filter({ daysLeft <= $0 }).min() else { return nil }
    guard alerted == nil || crossed < alerted! else { return nil }
    return crossed
}

/// Octopus doesn't report "plugged in" directly, so infer charging from the live power reading
/// and the smart-control state.
func chargingStatus(_ car: Car, now: Date) -> String? {
    let state = car.state ?? ""
    let freshPower = car.powerAsOf.map { now.timeIntervalSince($0) < 20 * 60 } ?? false

    // A lost connection explains anything else we might say, so it wins.
    if state == "LOST_CONNECTION" { return "Lost connection to car" }

    // isSuspended means Octopus's smart control is paused, not that charging has stopped: a
    // suspended car left plugged in still draws power. It says nothing when control isn't available.
    let paused = car.suspended == true && state != "SMART_CONTROL_NOT_AVAILABLE"
    func annotated(_ text: String) -> String { paused ? text + " · smart control paused" : text }

    if freshPower, let kw = car.powerKw, kw > 0.05 {
        let charging = String(format: "Charging %.1f kW", kw)
        switch state {
        case "BOOSTING": return charging + " · boost"
        case "SMART_CONTROL_IN_PROGRESS": return charging + " · smart charging"
        default: return annotated(charging)
        }
    }
    switch state {
    case "BOOSTING": return "Boost charge requested"
    case "SMART_CONTROL_IN_PROGRESS": return "Smart charging scheduled"
    case "SMART_CONTROL_NOT_AVAILABLE": return "Not charging · smart control not available"
    case "SMART_CONTROL_CAPABLE", "SMART_CONTROL_OFF", "SETUP_COMPLETE", "":
        if freshPower { return annotated("Not charging") }
        return paused ? "Smart control paused" : nil
    default: return annotated(state.replacingOccurrences(of: "_", with: " ").capitalized)
    }
}

func menuLines(_ s: Snapshot, now: Date) -> [Line] {
    let tz = s.tz
    let cal = calendar(tz)
    let intervals = cheapIntervals(s, now: now)
    let active = currentInterval(intervals, now: now)
    var lines: [Line] = []

    if !s.hasCheapRate {
        lines.append(.header("Single rate · \(pence(s.peakRate))"))
        lines.append(.text("This tariff has no cheap window"))
    } else if let active {
        lines.append(.header("Cheap rate now · \(pence(s.cheapRate))"))
        lines.append(.text("Back to standard at \(stamp(active.end, now: now, tz)) (\(pence(s.peakRate)))"))
    } else {
        lines.append(.header("Standard rate now · \(pence(s.peakRate))"))
        if let next = intervals.first {
            lines.append(.text("Cheap from \(stamp(next.start, now: now, tz)) (\(pence(s.cheapRate)))"))
        }
    }
    lines.append(.text(updatedLine(s, tz: tz)))

    // A single-rate tariff has no windows to list, so the section is skipped rather than shown
    // empty; everything below it still applies.
    if s.hasCheapRate {
        lines.append(.separator)
        lines.append(.header("Upcoming cheap rate"))
        if intervals.isEmpty { lines.append(.text("None in the next 48 hours")) }
        for i in intervals.prefix(6) {
            let isActive = i.start <= now
            let from = isActive ? "Now" : stamp(i.start, now: now, tz)
            let sameDay = cal.isDate(i.start, inSameDayAs: i.end)
            let to = sameDay ? formatted(i.end, "HH:mm", tz) : stamp(i.end, now: now, tz)
            var text = "\(from) – \(to)"
            if i.smart { text += "  (smart charge)" }
            lines.append(.text(text))
        }
    }

    lines.append(.separator)
    lines.append(.header(s.cars.count == 1 ? "Car" : "Cars"))
    if let planned = plannedChargeLine(s, now: now) { lines.append(.text(planned)) }
    if s.cars.isEmpty {
        lines.append(.text(s.devicesKnown ? "No smart devices found" : "Couldn't load smart devices"))
    }
    for car in s.cars {
        if let soc = car.soc {
            var title = "\(car.name): \(Int(soc.rounded()))%"
            if let target = car.target {
                var goal = "target \(target)%"
                if let readyBy = car.readyBy { goal += " by \(clockTime(readyBy))" }
                title += " (\(goal))"
            }
            lines.append(.text(title))
            // Derived from two figures the API does give, so "about": the state of charge arrives
            // rounded, and a percent of a 49 kWh battery is half a kilowatt-hour.
            if let capacity = car.batteryKwh, capacity > 0 {
                lines.append(
                    .text(
                        String(
                            format: "    About %.1f of %.1f kWh in the battery",
                            capacity * soc / 100, capacity)))
            }
            if let status = chargingStatus(car, now: now) { lines.append(.text("    " + status)) }
            if let asOf = car.asOf { lines.append(.text("    Charge level as of \(stamp(asOf, now: now, tz))")) }
        } else {
            lines.append(.text("\(car.name): no charge level reported"))
        }
    }

    lines += accountLines(s, now: now)
    lines += tariffLines(s, now: now)
    return lines
}

/// The account's money. Absent entirely when no balance came back, so an account with nothing to
/// say doesn't get an empty heading.
func accountLines(_ s: Snapshot, now: Date) -> [Line] {
    guard let balance = s.balancePence else { return [] }
    var lines: [Line] = [.separator, .header("Account"), .text("Balance: \(balanceText(balance))")]
    if let projected = s.projectedBalancePence {
        lines.append(.text("    \(balanceText(projected)) expected in a year"))
    }
    return lines
}

/// Every agreement the account holds, not merely the ones about to expire: a variable tariff
/// never expires, and leaving it out meant the menu never named the tariff its prices come from.
/// Nothing is merged — two houses on the same tariff are two agreements.
func tariffLines(_ s: Snapshot, now: Date) -> [Line] {
    guard !s.tariffEnds.isEmpty else { return [] }
    var lines: [Line] = [.separator, .header(s.tariffEnds.count == 1 ? "Tariff" : "Tariffs")]
    for end in s.tariffEnds {
        // The address only earns its place when the account has more than one.
        let at = s.propertyCount > 1 && !end.property.isEmpty ? " at \(end.property)" : ""
        lines.append(.text("\(end.name) (\(end.fuel.rawValue))\(at)"))
        guard let ending = end.ends else {
            lines.append(.text("    No end date"))
            continue
        }
        let last = lastCoveredDay(ending, s.tz)
        let days = daysUntil(last, now: now, s.tz)
        let when = days <= 0 ? "last day today" : dayCount(days)
        lines.append(.text("    Ends \(formatted(last, "EEE d MMM", s.tz)) · \(when)"))
    }
    return lines
}

/// One place to say the prices include VAT, and to carry the standing charge when known.
func updatedLine(_ s: Snapshot, tz: TimeZone) -> String {
    var text = "Prices include VAT"
    if let standing = s.standingCharge {
        text += String(format: " · standing charge %.2fp/day", standing)
    }
    return text + " · updated \(formatted(s.fetched, "HH:mm", tz))"
}
