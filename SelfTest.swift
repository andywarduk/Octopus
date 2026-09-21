// Self test (no network): OctopusMenuBar --selftest

import Foundation

func selfTest() {
    let tz = TimeZone(identifier: "Europe/London")!
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let snap = Snapshot(
        cheapRate: 6.5714, peakRate: 28.9251, windows: fallbackWindows,
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
            .map { "\($0.rawValue) \(formatUsage(day.value($0, .kwh), .kwh))kWh/\(formatUsage(day.value($0, .money), .money))" }
        print("  \(formatted(day.start, "EEE d MMM", tzLondon)): \(parts.joined(separator: ", "))")
    }
    // A single-rate tariff must not produce a cheap band at all.
    let flatBuckets = buckets.map { UsageBucket(start: $0.start, label: $0.label, kwh: $0.kwh, pence: $0.pence, pricePerUnit: 30.37136) }
    print("  flat tariff threshold: \(priceThreshold(flatBuckets).map { "\($0)" } ?? "none")")
    print("  flat tariff bands: \(Set(flatBuckets.map { band(for: $0, threshold: priceThreshold(flatBuckets)).rawValue }).sorted())")
    for slot in aggregateUsage(buckets, standing: [], tz: tzLondon, by: .halfHour) {
        let parts = RateBand.allCases.filter { slot.value($0, .kwh) > 0 }.map(\.rawValue)
        print("  half hour \(formatted(slot.start, "HH:mm", tzLondon))–\(formatted(slot.end, "HH:mm", tzLondon)): \(parts.joined(separator: " + "))")
    }
    print("  niceMax: 39.4 -> \(niceMax(39.4)), 2.5 -> \(niceMax(2.5)), 417 -> \(niceMax(417)), 0 -> \(niceMax(0))")

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
