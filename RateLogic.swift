// Rate logic: pure functions over a Snapshot, so they can be tested without the network — cheap
// windows and rate changes, the smart-charge plan, how often to fetch, and when a tariff ending is
// worth an alert.

import Foundation

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

/// Whether a carbon intensity counts as green: at or under Octopus's own 100 gCO₂/kWh line.
func carbonIsLow(_ grams: Double) -> Bool { grams <= greenThresholdGrams }

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
    guard alerted.map({ crossed < $0 }) ?? true else { return nil }
    return crossed
}
