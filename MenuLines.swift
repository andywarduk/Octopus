// What the status item and its menu say: pure functions from a Snapshot to text, so the wording
// can be tested without a menu.

import Foundation

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

/// The status item's symbol. The shape says the carbon intensity — a leaf when it is green, smoke
/// when it isn't — and filling it (drawn in colour by the caller) says the cheap rate is on. With
/// carbon unknown it falls back to the bolt, which says the rate alone, as the icon always did.
func statusSymbol(cheap: Bool, lowCarbon: Bool?) -> String {
    let base: String
    switch lowCarbon {
    case true?: base = "leaf"
    case false?: base = "smoke"
    case nil: base = "bolt"
    }
    return cheap ? base + ".fill" : base
}

/// The status item's tooltip: the rate, then the carbon intensity when it is known.
func statusTip(_ s: Snapshot, cheap: Bool, carbon: CarbonReading?) -> String {
    var tip: String
    if !s.hasCheapRate {
        tip = "Single rate: \(pence(s.peakRate))"
    } else {
        tip = cheap ? "Cheap rate: \(pence(s.cheapRate))" : "Standard rate: \(pence(s.peakRate))"
    }
    if let carbon {
        tip += " · \(carbonIsLow(carbon.grams) ? "low" : "high") carbon, \(formatGrams(carbon.grams))"
    }
    return tip
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

/// - Parameter carbon: the regional carbon intensity forecast, when it has loaded.
func menuLines(_ s: Snapshot, now: Date, carbon: [CarbonReading] = []) -> [Line] {
    let tz = s.tz
    let cal = calendar(tz)
    let intervals = cheapIntervals(s, now: now)
    let active = currentInterval(intervals, now: now)
    var lines: [Line] = []

    // The VAT and standing-charge footnote is the subtitle of the line under the heading, the
    // prices it qualifies. With no such line — standard rate and no cheap window ahead — it
    // stands alone, still in the subtitle style.
    var next: String?
    if !s.hasCheapRate {
        lines.append(.header("Single rate · \(pence(s.peakRate))"))
        next = "This tariff has no cheap window"
    } else if let active {
        lines.append(.header("Cheap rate now · \(pence(s.cheapRate))"))
        next = "Back to standard at \(stamp(active.end, now: now, tz)) (\(pence(s.peakRate)))"
    } else {
        lines.append(.header("Standard rate now · \(pence(s.peakRate))"))
        if let upcoming = intervals.first {
            next = "Cheap from \(stamp(upcoming.start, now: now, tz)) (\(pence(s.cheapRate)))"
        }
    }
    lines.append(.info(next ?? "", detail: updatedLine(s, tz: tz)))

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

    // Next to the rates, since both answer "is now a good time to use power?".
    lines += carbonLines(carbon, now: now, tz: tz)

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
            var details: [String] = []
            // Derived from two figures the API does give, so "about": the state of charge arrives
            // rounded, and a percent of a 49 kWh battery is half a kilowatt-hour.
            if let capacity = car.batteryKwh, capacity > 0 {
                details.append(
                    String(format: "About %.1f of %.1f kWh in the battery", capacity * soc / 100, capacity))
            }
            if let status = chargingStatus(car, now: now) { details.append(status) }
            if let asOf = car.asOf { details.append("Charge level as of \(stamp(asOf, now: now, tz))") }
            lines.append(titled(title, details))
        } else {
            lines.append(.text("\(car.name): no charge level reported"))
        }
    }

    lines += accountLines(s, now: now)
    lines += tariffLines(s, now: now)
    return lines
}

/// The carbon intensity now, as the item that opens the carbon window, with when it is next green —
/// at or under the 100 gCO₂/kWh line the icon's leaf uses — as its subtitle. Until the forecast has
/// loaded, a plain "Carbon Intensity…" item in its place.
///
/// No "cleanest half hour" here: that is the carbon window's job, and the menu stays short.
func carbonLines(_ readings: [CarbonReading], now: Date, tz: TimeZone) -> [Line] {
    let ahead = readings.filter { $0.end > now }.sorted { $0.start < $1.start }
    // The window is always reachable, forecast or not: it says for itself what is missing.
    guard let current = ahead.first(where: { $0.start <= now }) else {
        return [.separator, .header("Carbon intensity"), .action("Carbon Intensity…", .carbon)]
    }

    // The run of green half hours containing, or next after, now — joined while they are contiguous.
    func greenRun(from index: Int) -> (start: Date, end: Date) {
        var end = ahead[index].end
        var next = index + 1
        while next < ahead.count, carbonIsLow(ahead[next].grams), ahead[next].start <= end {
            end = ahead[next].end
            next += 1
        }
        return (ahead[index].start, end)
    }
    let horizon = ahead.last?.end ?? now
    func until(_ end: Date) -> String {
        // Green to the end of the forecast is not the same as green until then.
        end >= horizon ? "for as far as the forecast goes" : "until \(stamp(end, now: now, tz))"
    }
    let green: String
    if carbonIsLow(current.grams), let index = ahead.firstIndex(of: current) {
        green = "Green (≤100 g) \(until(greenRun(from: index).end))"
    } else if let index = ahead.firstIndex(where: { $0.start > now && carbonIsLow($0.grams) }) {
        let run = greenRun(from: index)
        let sameDay = calendar(tz).isDate(run.start, inSameDayAs: run.end)
        let to = sameDay ? formatted(run.end, "HH:mm", tz) : stamp(run.end, now: now, tz)
        green = "Next green (≤100 g): \(stamp(run.start, now: now, tz))–\(to)"
    } else {
        let hours = Int((horizon.timeIntervalSince(now) / 3600).rounded())
        green = "Not green (≤100 g) in the next \(hours) hours"
    }
    // Like a tariff line, the figure itself opens the window, with when it is next green under it.
    return [
        .separator, .header("Carbon intensity"),
        .action("Now \(formatGrams(current.grams)) · \(current.index.title.lowercased())", .carbon, detail: green),
    ]
}

/// A title with its details under it in the subtitle style, or a plain line when there are none.
func titled(_ title: String, _ details: [String]) -> Line {
    details.isEmpty ? .text(title) : .info(title, detail: details.joined(separator: "\n"))
}

/// The account's money. Absent entirely when no balance came back, so an account with nothing to
/// say doesn't get an empty heading.
func accountLines(_ s: Snapshot, now: Date) -> [Line] {
    guard let balance = s.balancePence else { return [] }
    let projected = s.projectedBalancePence.map { "\(balanceText($0)) expected in a year" }
    return [.separator, .header("Account"), titled("Balance: \(balanceText(balance))", projected.map { [$0] } ?? [])]
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
        let title = "\(end.name) (\(end.fuel.rawValue))\(at)"
        var detail = "No end date"
        if let ending = end.ends {
            let last = lastCoveredDay(ending, s.tz)
            let days = daysUntil(last, now: now, s.tz)
            let when = days <= 0 ? "last day today" : dayCount(days)
            detail = "Ends \(formatted(last, "EEE d MMM", s.tz)) · \(when)"
        }
        // The tariff line itself opens its meter's usage, so a two-property account gets one per
        // address with no separate "Electricity Use…" item to match up. An export meter has no
        // usage, so its tariff stays plain text.
        if let meter = end.meter {
            lines.append(.action(title, .usage(meter), detail: detail))
        } else {
            lines.append(.info(title, detail: detail))
        }
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
