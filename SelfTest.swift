// Self test (no network): OctopusMenuBar --selftest

import Foundation

func selfTest() {
    let tz = TimeZone(identifier: "Europe/London")!
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let snap = Snapshot(
        cheapRate: 6.8999, peakRate: 30.3714, standingCharge: 54.81, windows: fallbackWindows,
        dispatches: [Interval(start: date("2026-09-20T12:00:00Z"), end: date("2026-09-20T13:30:00Z"), smart: true)],
        cars: [
            Car(name: "Mini Cooper", soc: 62, target: 100, state: "SMART_CONTROL_NOT_AVAILABLE", asOf: date("2026-09-19T14:08:36Z")),
            Car(name: "Test EV", soc: 45, target: 80, state: "SMART_CONTROL_IN_PROGRESS", asOf: date("2026-09-19T15:10:00Z"),
                powerKw: 7.2, powerAsOf: date("2026-09-19T15:10:00Z")),
        ],
        tz: tz, fetched: date("2026-09-19T15:13:00Z"))
    let then = date("2026-09-19T15:10:00Z")
    print("--- charging status")
    for (label, car) in [
        ("charging, suspended", Car(name: "", state: "SMART_CONTROL_CAPABLE", powerKw: 7.2, powerAsOf: then, suspended: true)),
        ("charging, smart", Car(name: "", state: "SMART_CONTROL_IN_PROGRESS", powerKw: 7.2, powerAsOf: then)),
        ("idle, suspended", Car(name: "", state: "SMART_CONTROL_CAPABLE", suspended: true)),
        ("idle, suspended, no control", Car(name: "", state: "SMART_CONTROL_NOT_AVAILABLE", suspended: true)),
        ("offline, suspended", Car(name: "", state: "LOST_CONNECTION", suspended: true)),
        ("idle, plugged in", Car(name: "", state: "SMART_CONTROL_CAPABLE", powerKw: 0, powerAsOf: then)),
        ("nothing known", Car(name: "")),
    ] {
        print("  \(label): \(chargingStatus(car, now: date("2026-09-19T15:13:00Z")) ?? "(no line)")")
    }

    print("--- usage banding")
    let tzLondon = TimeZone(identifier: "Europe/London")!
    let midnight = date("2026-09-18T23:00:00Z")   // 00:00 BST on the 19th
    let noon = date("2026-09-19T12:00:00Z")
    let buckets = [
        UsageBucket(start: midnight, label: "CONSUMPTION_CHARGE_ECO7_NIGHT_H", kwh: 3.0, pence: 20.7, pricePerUnit: 6.89997),
        UsageBucket(start: noon, label: "CONSUMPTION_CHARGE_ECO7_DAY_H", kwh: 1.0, pence: 30.37, pricePerUnit: 30.37136),
        UsageBucket(start: noon, label: "CONSUMPTION_CHARGE_EV_DEVICE_OFF_PEAK_H", kwh: 2.0, pence: 13.8, pricePerUnit: 6.89997),
        UsageBucket(start: noon, label: "CONSUMPTION_CHARGE_EV_DEVICE_PEAK_H", kwh: 0.5, pence: 15.19, pricePerUnit: 30.37136),
    ]
    let threshold = priceThreshold(buckets)
    print("  threshold: \(threshold.map { String(format: "%.2fp", $0) } ?? "none (single rate)")")
    for bucket in buckets {
        print("  \(bucket.label) @ \(String(format: "%.2f", bucket.pricePerUnit))p -> \(band(for: bucket, threshold: threshold).rawValue)")
    }
    for day in aggregateUsage(buckets, standing: [(midnight, 1.03)], tz: tzLondon, by: .day) {
        let parts = RateBand.allCases
            .filter { day.value($0, .kwh) > 0 }
            .map { band -> String in
                let price = day.price(band).map { String(format: " @ %.2fp", $0) } ?? ""
                return "\(band.rawValue) \(formatUsage(day.value(band, .kwh), .kwh))kWh\(price)"
            }
        print("  \(formatted(day.start, "EEE d MMM", tzLondon)): \(parts.joined(separator: ", "))"
            + (day.smartCharge ? "  [smart charge]" : ""))
    }
    // A single-rate tariff must not produce a cheap band at all.
    let flatBuckets = buckets.map { UsageBucket(start: $0.start, label: $0.label, kwh: $0.kwh, pence: $0.pence, pricePerUnit: 30.37136) }
    print("  flat tariff threshold: \(priceThreshold(flatBuckets).map { "\($0)" } ?? "none")")
    print("  flat tariff bands: \(Set(flatBuckets.map { band(for: $0, threshold: priceThreshold(flatBuckets)).rawValue }).sorted())")
    for slot in aggregateUsage(buckets, standing: [], tz: tzLondon, by: .halfHour) {
        let parts = RateBand.allCases.filter { slot.value($0, .kwh) > 0 }
            .map { "\($0.rawValue) \(formatUsage(slot.value($0, .kwh), .kwh))kWh" }
        print("  half hour \(formatted(slot.start, "HH:mm", tzLondon))–\(formatted(slot.end, "HH:mm", tzLondon)): "
            + parts.joined(separator: " + ") + (slot.smartCharge ? "  [smart charge]" : ""))
    }
    // A day the API returned nothing for must still get a column.
    let dayOne = date("2026-09-17T23:00:00Z")   // 00:00 BST on the 18th
    let dayFour = date("2026-09-20T23:00:00Z")  // 00:00 BST on the 21st
    let padded = aggregateUsage(
        buckets, standing: [], tz: tzLondon, by: .day, window: (dayOne, dayFour))
    print("  window 18–20 Sep with data only on the 19th -> \(padded.count) columns:")
    for day in padded {
        let state = day.hasData ? formatUsage(day.total(.kwh), .kwh, withUnit: true) : "no data published"
        print("    \(formatted(day.start, "EEE d MMM", tzLondon)): \(state)")
    }
    // Gas puts the energy on the reading and leaves the statistic's value null; electricity
    // does the opposite. Both shapes must parse.
    print("  reading shapes:")
    let gasStat = ["type": "CONSUMPTION_COST", "label": "CONSUMPTION", "value": NSNull(),
                   "costInclTax": ["estimatedAmount": "64.20", "pricePerUnit": NSNull()]] as [String: Any]
    let elecStat = ["type": "CONSUMPTION_COST", "label": "CONSUMPTION_CHARGE_ECO7_NIGHT_H", "value": "3.0",
                    "costInclTax": ["estimatedAmount": "20.70", "pricePerUnit": ["amount": "6.89997"]]] as [String: Any]
    for (name, stats, reading) in [
        ("gas, one bucket, null value", [gasStat], 10.7541),
        ("electricity, bucket carries kWh", [elecStat], 0.0),
        ("two buckets, both null", [gasStat, gasStat], 10.7541),
    ] {
        let consumption = stats.filter { ($0["type"] as? String) == "CONSUMPTION_COST" }
        let parsed = stats.compactMap { stat -> String? in
            let money = stat["costInclTax"] as? [String: Any] ?? [:]
            let amount = toDouble(money["estimatedAmount"]) ?? 0
            let energy = toDouble(stat["value"]) ?? (consumption.count == 1 ? reading : 0)
            guard energy > 0 else { return nil }
            let quoted = toDouble((money["pricePerUnit"] as? [String: Any])?["amount"])
            return String(format: "%.4f kWh @ %.2fp", energy, quoted ?? (amount / energy))
        }
        print("    \(name): \(parsed.isEmpty ? "nothing parsed" : parsed.joined(separator: ", "))")
    }

    // A meter that used nothing still reports: standing charges arrive with no consumption.
    let quietDay = date("2026-09-18T23:00:00Z")
    let quiet = aggregateUsage(
        [], standing: (0..<48).map { (quietDay.addingTimeInterval(Double($0) * 1800), 0.68) },
        tz: tzLondon, by: .day, window: (quietDay, quietDay.addingTimeInterval(86400)))
    for day in quiet {
        print("  zero-usage day: hasData \(day.hasData), total \(formatUsage(day.total(.kwh), .kwh, withUnit: true)), "
            + "standing \(formatUsage(day.standingPence, .money))")
    }

    // The standing charge is a band in money and absent in kWh.
    print("  standing charge as a band:")
    for day in aggregateUsage(
        buckets, standing: [(midnight, 32.52)], tz: tzLondon, by: .day,
        window: (midnight, midnight.addingTimeInterval(86400)))
    {
        for (unit, scale) in [
            (UsageUnit.kwh, Granularity.day), (.money, .day), (.money, .halfHour),
        ] {
            let shown = visibleBands(unit, scale)
            let parts = shown.filter { day.value($0, unit) > 0 }
                .map { "\($0.rawValue) \(formatUsage(day.value($0, unit), unit))" }
            let name = "\(unit == .kwh ? "kWh" : "money")/\(scale == .day ? "day" : "half hour")"
            print("    \(name.padding(toLength: 16, withPad: " ", startingAt: 0)): "
                + "\(parts.joined(separator: ", "))  total \(formatUsage(day.total(unit, shown), unit))")
        }
    }

    print("  week windows (7 days each):")
    for back in [0, 1, 2] {
        let w = usageDateWindow(weeksBack: back, days: 7, tz: tzLondon)
        let last = calendar(tzLondon).date(byAdding: .day, value: -1, to: w.to)!
        print("    \(back) weeks back: \(formatted(w.from, "EEE d MMM", tzLondon)) – \(formatted(last, "EEE d MMM", tzLondon))")
    }
    // applicableRates quotes before tax; the tariff's own rates already include it.
    print("  VAT handling:")
    for (label, exVat) in [("standard", 28.9251), ("off-peak", 6.5714)] {
        print(String(format: "    %@: %.4fp ex VAT -> %.4fp incl", label, exVat, exVat * vatMultiplier))
    }

    // A part-published day must not make the week look settled, or the rest never arrives.
    print("  completeness:")
    let dayStart = date("2026-09-18T23:00:00Z")   // 00:00 BST
    let dayEnd = dayStart.addingTimeInterval(86400)
    func series(halfHoursPublished: Int, halfHourly: Bool) -> UsageSeries {
        UsageSeries(
            buckets: [], standing: (0..<halfHoursPublished).map { (dayStart.addingTimeInterval(Double($0) * 1800), 0.68) },
            tz: tzLondon, from: dayStart, to: dayEnd, supportsHalfHour: halfHourly, readings: max(1, halfHoursPublished))
    }
    for (label, s) in [
        ("half-hourly, 2 of 48 published", series(halfHoursPublished: 2, halfHourly: true)),
        ("half-hourly, all 48 published", series(halfHoursPublished: 48, halfHourly: true)),
        ("daily meter, day published", series(halfHoursPublished: 1, halfHourly: false)),
    ] {
        print("    \(label): complete=\(s.isComplete)")
    }

    print("  cache freshness:")
    let settled = CachedUsage(series: UsageSeries(), fetchedAt: date("2026-01-01T00:00:00Z"), complete: true)
    let pending = CachedUsage(series: UsageSeries(), fetchedAt: date("2026-01-01T00:00:00Z"), complete: false)
    let justNow = CachedUsage(series: UsageSeries(), fetchedAt: Date(), complete: false)
    print("    settled week, fetched months ago: \(settled.isFresh())")
    print("    incomplete week, fetched months ago: \(pending.isFresh())")
    print("    incomplete week, fetched just now: \(justNow.isFresh())")
    print("  axis scale (max, step, ticks):")
    for value in [3.9, 2.5, 5.0, 7.4, 39.4, 59.3, 417.0, 0.3, 0.0] {
        let (top, step) = axisScale(value)
        let ticks = stride(from: 0.0, through: top + step / 2, by: step)
            .map { String(format: "%g", $0) }
        print("    \(value) -> max \(String(format: "%g", top)) step \(String(format: "%g", step)): \(ticks.joined(separator: ", "))")
    }

    var flat = snap
    flat.cheapRate = flat.peakRate
    for (label, now, s) in [
        ("Sat 16:13 BST", "2026-09-19T15:13:00Z", snap),
        ("Sun 02:00 BST", "2026-09-20T01:00:00Z", snap),
        ("flat tariff", "2026-09-20T01:00:00Z", flat),
    ] {
        print("--- \(label): cheap=\(isCheap(s, now: date(now)))")
        for line in menuLines(s, now: date(now)) {
            switch line {
            case .separator: print("  ------")
            case .header(let t): print("  [\(t)]")
            case .text(let t): print("  \(t)")
            }
        }
    }
}
