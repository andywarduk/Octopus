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
