// Self test (no network): OctopusMenuBar --selftest

import AppKit
import Foundation
import ServiceManagement

func selfTest() {
    let tz = TimeZone(identifier: "Europe/London")!
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let snap = Snapshot(
        cheapRate: 6.8999, peakRate: 30.3714, standingCharge: 54.81, windows: fallbackWindows,
        dispatches: [
            Interval(
                start: date("2026-09-20T12:00:00Z"), end: date("2026-09-20T13:30:00Z"), smart: true,
                plannedKwh: 7.833, chargeType: "SMART")
        ],
        cars: [
            Car(name: "Mini Cooper", soc: 62, batteryKwh: 49.2, target: 80, readyBy: 7 * 60,
                state: "SMART_CONTROL_NOT_AVAILABLE", asOf: date("2026-09-19T14:08:36Z")),
            Car(name: "Test EV", soc: 45, target: 80, state: "SMART_CONTROL_IN_PROGRESS", asOf: date("2026-09-19T15:10:00Z"),
                powerKw: 7.2, powerAsOf: date("2026-09-19T15:10:00Z")),
        ],
        balancePence: 53206, projectedBalancePence: 71062,
        tariffEnds: [
            TariffEnd(
                fuel: .electricity, name: "Octopus 12M Fixed", ends: date("2026-10-08T23:00:00Z"),
                property: "9 Other Road"),
            TariffEnd(
                fuel: .gas, name: "Octopus 12M Fixed", ends: date("2026-10-08T23:00:00Z"),
                property: "1 Test Lane"),
            TariffEnd(
                fuel: .gas, name: "Octopus 12M Fixed", ends: date("2026-10-08T23:00:00Z"),
                property: "9 Other Road"),
            // The variable tariff the menu bar's prices come from: no end date, and it must
            // still be listed.
            TariffEnd(fuel: .electricity, name: "Intelligent Octopus Go", property: "1 Test Lane"),
        ],
        propertyCount: 2,
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
        // A fixed day, not the clock, or the expected output goes stale at midnight.
        let w = usageDateWindow(weeksBack: back, days: 7, tz: tzLondon, now: date("2026-09-23T12:00:00Z"))
        let last = calendar(tzLondon).date(byAdding: .day, value: -1, to: w.to)!
        print("    \(back) weeks back: \(formatted(w.from, "EEE d MMM", tzLondon)) – \(formatted(last, "EEE d MMM", tzLondon))")
    }
    // applicableRates quotes before tax; the tariff's own rates already include it.
    print("  VAT handling:")
    for (label, exVat) in [("standard", 28.9251), ("off-peak", 6.5714)] {
        print(String(format: "    %@: %.4fp ex VAT -> %.4fp incl", label, exVat, exVat * vatMultiplier))
    }

    // Octopus re-plans slots by a few minutes constantly; only a real change should alert.
    print("  dispatch changes:")
    func slot(_ from: String, _ to: String) -> Interval {
        Interval(start: date(from), end: date(to), smart: true)
    }
    let planned = [slot("2026-09-20T00:30:00Z", "2026-09-20T03:00:00Z")]
    for (label, old, new) in [
        ("unchanged", planned, planned),
        ("shifted 3 min", planned, [slot("2026-09-20T00:33:00Z", "2026-09-20T03:03:00Z")]),
        ("shifted 40 min", planned, [slot("2026-09-20T01:10:00Z", "2026-09-20T03:40:00Z")]),
        ("slot added", planned, planned + [slot("2026-09-20T13:00:00Z", "2026-09-20T14:00:00Z")]),
        ("slot dropped", planned + [slot("2026-09-20T13:00:00Z", "2026-09-20T14:00:00Z")], planned),
        ("all cancelled", planned, []),
        ("first plan", [], planned),
    ] {
        let change = dispatchChange(from: old, to: new, tz: tzLondon)
        print("    \(label.padding(toLength: 16, withPad: " ", startingAt: 0)): "
            + (change.map { "\($0.title) — \($0.body)" } ?? "no alert"))
    }

    // A change made during the cooldown must still be announced once it ends, and a plan that
    // flaps and settles back must not be.
    print("  dispatch alert cooldown:")
    let otherSlot = slot("2026-09-20T13:00:00Z", "2026-09-20T14:00:00Z")
    let lateSlot = slot("2026-09-20T15:00:00Z", "2026-09-20T16:00:00Z")
    let gateStart = date("2026-09-19T20:00:00Z")
    for (label, steps) in [
        ("change inside the cooldown", [
            (0.0, planned, planned + [otherSlot]),
            (5, planned + [otherSlot], planned + [otherSlot, lateSlot]),
            (11, planned + [otherSlot, lateSlot], planned + [otherSlot, lateSlot]),
        ]),
        ("flap that settles back", [
            (0.0, planned, planned + [otherSlot]),
            (3, planned + [otherSlot], planned),
            (6, planned, planned + [otherSlot]),
            (12, planned + [otherSlot], planned + [otherSlot]),
        ]),
    ] as [(String, [(Double, [Interval], [Interval])])] {
        var gate = DispatchAlertGate()
        let outcomes = steps.map { minutes, previous, current in
            let result = gate.check(
                previous: previous, current: current, now: gateStart.addingTimeInterval(minutes * 60),
                tz: tzLondon)
            return "\(Int(minutes))m " + (result?.title ?? (gate.held == nil ? "quiet" : "held"))
        }
        print("    \(label.padding(toLength: 28, withPad: " ", startingAt: 0)): "
            + outcomes.joined(separator: " → "))
    }

    // A failed device query is "don't know", not "no car and nothing planned".
    print("  device query failure:")
    var failedDevices = snap
    failedDevices.cars = []
    failedDevices.dispatches = []
    failedDevices.devicesKnown = false
    let beforeFailure = date("2026-09-20T10:00:00Z")
    let carried = carryForwardDevices(failedDevices, from: snap, now: beforeFailure)
    print("    after a good fetch: cars \(carried.cars.count), planned \(futureDispatches(carried, now: beforeFailure).count), "
        + "known \(carried.devicesKnown), cheap at 12:30Z \(isCheap(carried, now: date("2026-09-20T12:30:00Z")))")
    let uncarried = carryForwardDevices(failedDevices, from: nil, now: beforeFailure)
    let deviceLines = menuLines(uncarried, now: beforeFailure).compactMap { line -> String? in
        if case .text(let text) = line, text.contains("smart devices") { return text }
        return nil
    }
    print("    first fetch: known \(uncarried.devicesKnown), menu says \"\(deviceLines.joined())\"")

    // A refresh reuses the tariff for an hour, but never across a meter change or when asked for.
    print("  refresh split:")
    let fetchedTariff = date("2026-09-19T15:00:00Z")
    let cachedTariff = TariffState(
        accountNumber: "A-1", mpan: "1000", cheapRate: 6.9, peakRate: 30.37, windows: fallbackWindows,
        tz: tzLondon, tariffEnds: [], propertyCount: 1, fetched: fetchedTariff)
    for (label, cached, mpan, minutes, force) in [
        ("5 min old", cachedTariff, "1000", 5.0, false),
        ("59 min old", cachedTariff, "1000", 59, false),
        ("61 min old", cachedTariff, "1000", 61, false),
        ("Refresh Now", cachedTariff, "1000", 5, true),
        ("another meter", cachedTariff, "2000", 5, false),
        ("nothing cached", nil, "1000", 5, false),
    ] as [(String, TariffState?, String, Double, Bool)] {
        let reuse = tariffIsReusable(
            cached, account: "A-1", mpan: mpan, now: fetchedTariff.addingTimeInterval(minutes * 60), force: force)
        print("    tariff \(label.padding(toLength: 16, withPad: " ", startingAt: 0)): \(reuse ? "reused" : "fetched")")
    }
    func fieldCount(_ query: String) -> String {
        let aliases = query.components(separatedBy: "flexPlannedDispatches").count - 1
        return "\(aliases) plan alias\(aliases == 1 ? "" : "es"), rates \(query.contains("applicableRates") ? "included" : "omitted")"
    }
    print("    device query, fixed rates, no ids yet: \(fieldCount(deviceQuery(deviceIds: [], includeRates: false)))")
    print("    device query, Agile, two ids: \(fieldCount(deviceQuery(deviceIds: ["d1", "d2"], includeRates: true)))")
    let agileNode: [String: Any] = [
        "balance": 1200,
        "electricityAgreements": [
            ["meterPoint": ["mpan": "1000"], "tariff": ["displayName": "Agile Octopus"],
             "timeOfUseScheme": ["timezone": "Europe/London", "timeslots": []]],
        ],
    ]
    let agile = try? parseTariffState(agileNode, account: "A-1", mpan: "1000", now: fetchedTariff)
    print("    tariff with no fixed rates: ratesFromTariff=\(agile?.ratesFromTariff ?? true), "
        + "windows \(agile?.windows.map { "\(clockTime($0.from))–\(clockTime($0.to))" } ?? [])")
    // Intelligent Octopus Go arrives as a HalfHourlyTariff: no named rates, but a standing charge.
    let iogNode: [String: Any] = [
        "electricityAgreements": [
            ["meterPoint": ["mpan": "1000"],
             "tariff": ["__typename": "HalfHourlyTariff", "displayName": "Intelligent Octopus Go", "standingCharge": 49.41]],
        ],
    ]
    let iog = try? parseTariffState(iogNode, account: "A-1", mpan: "1000", now: fetchedTariff)
    print("    HalfHourlyTariff: ratesFromTariff=\(iog?.ratesFromTariff ?? true), "
        + "standing \(iog?.standingCharge.map { String(format: "%.2fp", $0) } ?? "none")")
    let reply: [String: Any] = [
        "devices": [
            ["__typename": "SmartFlexVehicle", "id": "d1", "make": "MINI", "model": "Cooper",
             "vehicleBatterySize": "49.2", "status": ["stateOfCharge": ["value": 62]]],
            ["__typename": "SmartMeterDevice", "id": "m1"],
        ],
        "f0": [["start": "2026-09-19T23:30:00+00:00", "end": "2026-09-20T00:00:00+00:00",
                "type": "SMART", "energyAddedKwh": -2.611]],
        "completedDispatches": [["start": "2026-09-19T12:00:00+00:00", "end": "2026-09-19T12:30:00+00:00"]],
    ]
    let parsed = parseDeviceState(reply, deviceIds: ["d1"], now: fetchedTariff, tz: tzLondon)
    print("    device reply: ids \(smartDeviceIds(reply)), cars \(parsed.cars.map(\.name)), "
        + "dispatches \(parsed.dispatches.count), planned \(parsed.dispatches.compactMap(\.plannedKwh))")

    print("  tariff end dates:")
    // Shapes that must not become an expiry: no end date at all (a variable tariff), one that has
    // already passed, a revoked agreement, and one that hasn't started yet.
    let accountNode: [String: Any] = [
        "properties": [
            [
                "id": "236766",
                "address": "1 Test Lane, Corsham, SN13 9XX",
                "electricityMeterPoints": [
                    ["agreements": [
                        ["validFrom": "2026-08-23T23:00:00+00:00", "validTo": NSNull(),
                         "tariff": ["displayName": "Intelligent Octopus Go"]],
                    ]],
                    ["agreements": [
                        ["validFrom": "2025-10-08T23:00:00+00:00", "validTo": "2026-10-08T23:00:00+00:00",
                         "tariff": ["displayName": "Octopus 12M Fixed"]],
                        ["validFrom": "2026-10-08T23:00:00+00:00", "validTo": "2027-10-08T23:00:00+00:00",
                         "tariff": ["displayName": "Next Year Fixed"]],
                        ["validFrom": "2024-01-01T00:00:00+00:00", "validTo": "2025-01-01T00:00:00+00:00",
                         "tariff": ["displayName": "Expired Fixed"]],
                        ["validFrom": "2025-10-08T23:00:00+00:00", "validTo": "2026-11-01T00:00:00+00:00",
                         "isRevoked": true, "tariff": ["displayName": "Revoked Fixed"]],
                    ]],
                ],
                // Two gas meters on the same tariff ending the same day: one thing to say.
                "gasMeterPoints": [
                    ["agreements": [
                        ["validFrom": "2025-10-08T23:00:00+00:00", "validTo": "2026-10-08T23:00:00+00:00",
                         "tariff": ["displayName": "Octopus 12M Fixed"]]
                    ]],
                    ["agreements": [
                        ["validFrom": "2025-10-08T23:00:00+00:00", "validTo": "2026-10-08T23:00:00+00:00",
                         "tariff": ["displayName": "Octopus 12M Fixed"]]
                    ]],
                ],
            ],
            // A second address, with a tariff of its own. Its expiry must be named, not shown as
            // though it belonged to the property the rest of the menu is about.
            [
                "id": "2897476",
                "address": "9 Other Road, Corsham, SN13 0YY",
                // A tariff only this address is on: the line must name it.
                "electricityMeterPoints": [
                    ["agreements": [
                        ["validFrom": "2025-10-08T23:00:00+00:00", "validTo": "2026-10-20T23:00:00+00:00",
                         "tariff": ["displayName": "Octopus 24M Fixed"]]
                    ]]
                ],
                "gasMeterPoints": [
                    ["agreements": [
                        ["validFrom": "2025-10-08T23:00:00+00:00", "validTo": "2026-10-08T23:00:00+00:00",
                         "tariff": ["displayName": "Octopus 12M Fixed"]]
                    ]]
                ],
            ],
        ]
    ]
    let places = propertyCount(accountNode)
    let parsedEnds = parseTariffEnds(accountNode, now: date("2026-09-22T12:00:00Z"))
    for end in parsedEnds {
        // The raw instant is midnight, so the last covered day is the one before it.
        let last = end.ends.map { lastCoveredDay($0, tzLondon) }
        print("    \(end.fuel.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) "
            + "\(end.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
            + "\(end.property.padding(toLength: 14, withPad: " ", startingAt: 0)) "
            + (last.map { "last day \(formatted($0, "EEE d MMM yyyy", tzLondon))" } ?? "no end date"))
    }
    print("    \(parsedEnds.count) agreements, \(places) properties; "
        + "\(endingSoon(parsedEnds, now: date("2026-09-22T12:00:00Z"), tz: tzLondon).count) end within "
        + "\(tariffNoticePeriod) days")

    print("  tariff alert thresholds (daysLeft, already alerted -> new alert):")
    for (days, alerted) in [(45, nil), (30, nil), (16, 30), (16, nil), (14, 30), (7, 14), (1, 7), (0, 1), (0, nil)]
        as [(Int, Int?)]
    {
        let result = tariffAlertThreshold(daysLeft: days, alerted: alerted)
        print("    \(String(days).padding(toLength: 3, withPad: " ", startingAt: 0)) days, "
            + "alerted \(alerted.map(String.init) ?? "never") -> "
            + (result.map { "alert at \($0)" } ?? "silent"))
    }

    print("  charge goal from the SmartFlex schedule:")
    func schedule(_ day: String, _ time: String, _ max: Any) -> [String: Any] {
        ["dayOfWeek": day, "time": time, "max": max, "upperLimit": max]
    }
    let saturday = date("2026-09-19T15:13:00Z")
    for (label, prefs) in [
        ("percentage, every day 07:00/80",
         ["unit": "PERCENTAGE", "schedules": ["SATURDAY", "SUNDAY"].map { schedule($0, "07:00:00", 80.0) }]),
        ("percentage, weekend differs",
         ["unit": "PERCENTAGE", "schedules": [schedule("SATURDAY", "09:30:00", 90.0), schedule("MONDAY", "07:00:00", 80.0)]]),
        // A kWh or mileage goal is not a state of charge and must not gain a % sign.
        ("kilowatt-hour target", ["unit": "KILOWATT_HOUR", "schedules": [schedule("SATURDAY", "07:00:00", 40.0)]]),
        ("no schedules", ["unit": "PERCENTAGE", "schedules": []]),
    ] as [(String, [String: Any])] {
        let goal = todaysChargeGoal(prefs, now: saturday, tz: tzLondon)
        print("    \(label.padding(toLength: 30, withPad: " ", startingAt: 0)): "
            + "target \(goal.target.map { "\($0)%" } ?? "none"), "
            + "ready by \(goal.readyBy.map(clockTime) ?? "unknown")")
    }
    print("    no preferences at all: "
        + "\(todaysChargeGoal(nil, now: saturday, tz: tzLondon).readyBy.map(clockTime) ?? "unknown")")

    print("  balance wording:")
    for value in [53206, 71062, 0, -1250] {
        print("    \(value)p -> \(balanceText(value))")
    }

    print("  carbon intensity parsing:")
    // Both sources name the same five bands in different spellings, and both have a shape that
    // silently yields nothing if mis-parsed: Octopus omits the period end, National Grid stamps
    // its times without seconds.
    print("    index spellings: "
        + ["VERY_LOW", "very low", "Very High", "moderate", "nonsense"]
            .map { "\($0)->\(CarbonIndex(apiValue: $0)?.title ?? "unparsed")" }
            .joined(separator: ", "))
    // An outward code on its own must survive: stripping three characters off "SN13" gives "S",
    // which both APIs reject.
    print("    outward codes: "
        + ["SN13 9XX", "sn13 9xx", "SN139XX", "M1 1AA", "M11AA", "SN13", "M1", ""]
            .map { "'\($0)'->'\(outwardCode($0))'" }.joined(separator: ", "))

    let octopusRows: [[String: Any]] = [
        ["periodStart": "2026-09-22T19:00:00+00:00", "value": 298.0, "index": "VERY_HIGH"],
        // Deliberately out of order: the end of each period is the next one's start, so the rows
        // have to be sorted before that can be worked out.
        ["periodStart": "2026-09-22T18:30:00+00:00", "value": 289.0, "index": "VERY_HIGH"],
        ["periodStart": "2026-09-22T19:30:00+00:00", "value": 287.0, "index": "VERY_HIGH"],
        ["periodStart": "2026-09-22T20:00:00+00:00", "value": NSNull(), "index": "HIGH"],
    ]
    let fromOctopus = parseOctopusCarbon(octopusRows)
    print("    Octopus: \(fromOctopus.count) of \(octopusRows.count) rows parsed")
    for reading in fromOctopus {
        print("      \(formatted(reading.start, "HH:mm", tzLondon))–\(formatted(reading.end, "HH:mm", tzLondon)) "
            + "\(formatGrams(reading.grams)) \(reading.index.title) mix=\(reading.mix.count)")
    }

    let gridRows: [[String: Any]] = [
        // No seconds in either stamp: ISO8601DateFormatter rejects this under .withInternetDateTime.
        ["from": "2026-09-22T17:30Z", "to": "2026-09-22T18:00Z",
         "intensity": ["forecast": 291, "index": "very high"],
         "generationmix": [["fuel": "gas", "perc": 69.9], ["fuel": "wind", "perc": 2.6],
                           ["fuel": "coal", "perc": 0.0]]],
        // A past period carries `actual` as well, which should win over the forecast.
        ["from": "2026-09-22T18:00Z", "to": "2026-09-22T18:30Z",
         "intensity": ["forecast": 280, "actual": 273, "index": "very high"],
         "generationmix": [["fuel": "gas", "perc": 65.5]]],
        ["from": "2026-09-22T18:30Z", "to": "2026-09-22T19:00Z",
         "intensity": ["forecast": NSNull(), "index": "high"]],
    ]
    let fromGrid = parseNationalGridCarbon(gridRows)
    print("    National Grid: \(fromGrid.count) of \(gridRows.count) rows parsed")
    for reading in fromGrid {
        let mix = reading.mix.map { String(format: "%@ %.1f", $0.fuel.title, $0.percent) }
            .joined(separator: ", ")
        print("      \(formatted(reading.start, "HH:mm", tzLondon))–\(formatted(reading.end, "HH:mm", tzLondon)) "
            + "\(formatGrams(reading.grams)) \(reading.index.title) [\(mix)]")
    }

    let forecast = sampleCarbonForecast(from: date("2026-09-22T17:00:00Z"))
    let carbonSeries = CarbonSeries(
        source: .nationalGrid, region: "South England", outward: "SN13", readings: forecast,
        fetchedAt: date("2026-09-22T17:05:00Z"))
    let cleanest = carbonSeries.cleanest
    print("    sample forecast: \(forecast.count) half hours, "
        + "cleanest \(cleanest.map { formatted($0.start, "EEE HH:mm", tzLondon) } ?? "none") at "
        + "\(cleanest.map { formatGrams($0.grams) } ?? "-")")
    let soonAfter = carbonSeries.isFresh(now: date("2026-09-22T17:20:00Z"))
    let anHourLater = carbonSeries.isFresh(now: date("2026-09-22T18:10:00Z"))
    print("    freshness: forecast just fetched=\(soonAfter), an hour old=\(anHourLater)")
    // A past week can't change, so it stays fresh however long ago it was fetched. The current
    // week can, and must not.
    var pastWeek = carbonSeries
    pastWeek.period = .week(back: 3)
    var thisWeek = carbonSeries
    thisWeek.period = .week(back: 0)
    print("    freshness: past week after a day=\(pastWeek.isFresh(now: date("2026-09-23T17:05:00Z"))), "
        + "current week after a day=\(thisWeek.isFresh(now: date("2026-09-23T17:05:00Z")))")

    // Unknown fuels must fold into `other` and add up, not each claim the slot — a column has to
    // keep totalling 100%.
    let mixRow: [[String: Any]] = [[
        "from": "2026-09-22T17:30Z", "to": "2026-09-22T18:00Z",
        "intensity": ["forecast": 180, "index": "high"],
        "generationmix": [
            ["fuel": "wind", "perc": 34.0], ["fuel": "gas", "perc": 42.9],
            ["fuel": "fusion", "perc": 2.0], ["fuel": "unobtainium", "perc": 1.1],
            ["fuel": "nuclear", "perc": 20.0], ["fuel": "coal", "perc": 0.0],
        ],
    ]]
    let mixed = parseNationalGridCarbon(mixRow)[0].mix
    print("    fuel mapping: "
        + mixed.map { String(format: "%@ %.1f", $0.fuel.title, $0.percent) }.joined(separator: ", "))
    print("    stack order matches GridFuel: "
        + "\(mixed.map(\.fuel) == GridFuel.allCases.filter { f in mixed.contains { $0.fuel == f } }), "
        + "total \(String(format: "%.1f", mixed.reduce(0) { $0 + $1.percent }))")

    // The mix view's bars stand at GB demand while the intensity view is regional, and the mix
    // behind them can be either basis in one window. The footer has to say which, so that
    // wording is worth pinning down.
    print("    mix basis wording:")
    // Readings start at 00:00Z; a fetch at `fetchedAt` has seen the ones ending by then happen.
    func basis(national: Int, regional: Int, demand: Int, fetchedAt: String = "2026-09-22T06:00:00Z") -> CarbonSeries {
        var readings: [CarbonReading] = []
        for position in 0..<(national + regional) {
            let from = date("2026-09-22T00:00:00Z").addingTimeInterval(Double(position) * 1800)
            readings.append(
                CarbonReading(
                    start: from, end: from.addingTimeInterval(1800), grams: 200, index: .high,
                    mix: [FuelShare(fuel: .gas, percent: 100)],
                    demandMW: position < demand ? 30_000 : nil,
                    mixIsNational: position < national))
        }
        return CarbonSeries(
            source: .nationalGrid, region: "South England", outward: "SN13", readings: readings,
            fetchedAt: date(fetchedAt))
    }
    for (label, series) in [
        ("all national, all past", basis(national: 4, regional: 0, demand: 4)),
        // The forecast view: every half hour still to come. This was labelled "GB actual".
        ("all national, all ahead", basis(national: 4, regional: 0, demand: 4, fetchedAt: "2026-09-22T00:00:00Z")),
        ("national, past then ahead", basis(national: 4, regional: 0, demand: 4, fetchedAt: "2026-09-22T01:00:00Z")),
        ("all regional, no demand", basis(national: 0, regional: 4, demand: 0)),
        ("national then regional, part demand", basis(national: 2, regional: 2, demand: 3)),
    ] {
        print("      \(label.padding(toLength: 36, withPad: " ", startingAt: 0)): "
            + "\(series.mixBasis), hasDemand=\(series.hasDemand)")
    }
    // The real glitch of 23 September 2026 and the sound half hours either side of it.
    print("    implausible mix screening (real values):")
    for (label, solar, gas, demand) in [
        ("05:30Z  78.3% solar", 78.3, 4.4, 24_277.0),
        ("06:00Z  84.5% solar", 84.5, 2.2, 26_645.0),
        ("06:30Z   2.2% solar", 2.2, 32.7, 27_400.0),
        ("midsummer noon, 30% of a low demand", 30.0, 20.0, 24_000.0),
        ("no demand known", 84.5, 2.2, -1.0),
    ] as [(String, Double, Double, Double)] {
        let reading = CarbonReading(
            start: date("2026-09-23T05:30:00Z"), end: date("2026-09-23T06:00:00Z"), grams: 8,
            index: .veryLow,
            mix: [
                FuelShare(fuel: .gas, percent: gas), FuelShare(fuel: .solar, percent: solar),
                FuelShare(fuel: .wind, percent: 100 - gas - solar),
            ],
            demandMW: demand < 0 ? nil : demand)
        let implied = reading.impliedSolarMW.map { String(format: "%.1f GW", $0 / 1000) } ?? "unknown"
        print("      \(label.padding(toLength: 36, withPad: " ", startingAt: 0)): implied solar "
            + "\(implied.padding(toLength: 9, withPad: " ", startingAt: 0)) -> "
            + (mixLooksImplausible(reading) ? "SUSPECT" : "ok"))
    }
    print("      ceiling \(Int(gbSolarCeilingMW / 1000)) GW, against a GB record near 14 GW")

    // Elexon publishes settled demand when a half hour ends, and drops it from the day-ahead
    // forecast once it starts, so the period in progress is briefly covered by neither. That is
    // not the same as running off the end of the forecast, and must not be described as if it is.
    print("    demand gaps:")
    let atNow = date("2026-09-22T20:03:00Z")
    for (label, start, demand) in [
        ("settled, an hour ago", "2026-09-22T19:00:00Z", 29_969.0),
        ("just ended, not yet published", "2026-09-22T19:30:00Z", -1),
        ("in progress", "2026-09-22T20:00:00Z", -1),
        ("forecast, later tonight", "2026-09-22T21:00:00Z", 28_339.0),
        ("past the forecast horizon", "2026-09-24T10:00:00Z", -1),
    ] as [(String, String, Double)] {
        let reading = CarbonReading(
            start: date(start), end: date(start).addingTimeInterval(1800), grams: 180, index: .high,
            mix: [FuelShare(fuel: .gas, percent: 100)], demandMW: demand < 0 ? nil : demand)
        print("      \(label.padding(toLength: 32, withPad: " ", startingAt: 0)): "
            + "\(demandGap(reading, now: atNow))")
    }

    // The cleanest half hour is what the footer recommends acting on, so a glitched reading must
    // never win it — the sunrise misfire reports single figures.
    print("    cleanest excludes implausible readings:")
    var withGlitch: [CarbonReading] = []
    for (position, grams) in [52.0, 284, 5, 49, 37].enumerated() {
        let from = date("2026-09-22T20:00:00Z").addingTimeInterval(Double(position) * 1800)
        withGlitch.append(
            CarbonReading(
                start: from, end: from.addingTimeInterval(1800), grams: grams,
                index: grams < 50 ? .veryLow : .high, mix: [], demandMW: 26_000,
                // The 5 gCO₂ reading is the sunrise glitch.
                suspectMix: grams == 5))
    }
    let glitched = CarbonSeries(
        source: .octopus, outward: "SN13", readings: withGlitch, fetchedAt: Date())
    print("      values \(withGlitch.map { Int($0.grams) }) -> cleanest "
        + "\(glitched.cleanest.map { formatGrams($0.grams) } ?? "none"), "
        + "\(glitched.suspectCount) suspect")

    print("    mean mix skips implausible half hours:")
    let sunrise = [40.0, 40, 2, 40].enumerated().map { position, gas in
        CarbonReading(
            start: date("2026-09-23T04:30:00Z").addingTimeInterval(Double(position) * 1800),
            end: date("2026-09-23T05:00:00Z").addingTimeInterval(Double(position) * 1800), grams: 150,
            index: .moderate,
            mix: [FuelShare(fuel: .gas, percent: gas), FuelShare(fuel: .solar, percent: 100 - gas)],
            suspectMix: gas == 2)
    }
    let means = averageMix(sunrise)
    print(String(format: "      gas %.1f%%, solar %.1f%% (with the glitch counted: gas %.1f%%)",
        means[.gas] ?? 0, means[.solar] ?? 0, sunrise.reduce(0) { $0 + ($1.mix.first?.percent ?? 0) } / 4))

    print("    power formatting: "
        + [30_634.0, 21_800, 1_050, 0].map { formatPower($0) }.joined(separator: ", "))

    print("  carbon window navigation:")
    // Stepping back from the forecast lands on the current week; forward past it returns there.
    var at = CarbonPeriod.forecast
    func step(_ delta: Int) -> String {
        switch at {
        case .forecast: at = delta > 0 ? .week(back: 0) : .forecast
        case .week(let back): at = back + delta < 0 ? .forecast : .week(back: back + delta)
        }
        return at.weeksBack.map { "week -\($0)" } ?? "forecast"
    }
    print("    back, back, back, forward, forward, forward: "
        + [step(1), step(1), step(1), step(-1), step(-1), step(-1)].joined(separator: " → "))

    // A part-published day must not make the week look settled, or the rest never arrives.
    print("  completeness:")
    let dayStart = date("2026-09-18T23:00:00Z")   // 00:00 BST
    let dayEnd = dayStart.addingTimeInterval(86400)
    func series(halfHoursPublished: Int, halfHourly: Bool) -> UsageSeries {
        UsageSeries(
            buckets: [], standing: (0..<halfHoursPublished).map { (dayStart.addingTimeInterval(Double($0) * 1800), 0.68) },
            tz: tzLondon, from: dayStart, to: dayEnd, supportsHalfHour: halfHourly, readings: max(1, halfHoursPublished))
    }
    // The day the clocks go back has 50 half hours. Asking for 48 cut off its last hour, which
    // then read as unpublished forever and kept the week from ever settling.
    print("    page size per local day: " + [
        ("spring forward", "2026-03-29T00:00:00Z", "2026-03-29T23:00:00Z"),
        ("ordinary", "2026-09-18T23:00:00Z", "2026-09-19T23:00:00Z"),
        ("fall back", "2026-10-24T23:00:00Z", "2026-10-26T00:00:00Z"),
    ].map { "\($0.0) \(halfHours(from: date($0.1), to: date($0.2)))" }.joined(separator: ", "))
    let longDay = UsageSeries(
        buckets: [], standing: (0..<50).map { (date("2026-10-24T23:00:00Z").addingTimeInterval(Double($0) * 1800), 0.68) },
        tz: tzLondon, from: date("2026-10-24T23:00:00Z"), to: date("2026-10-26T00:00:00Z"), readings: 50)
    print("    half-hourly, all 50 published on the day the clocks go back: complete=\(longDay.isComplete)")
    for (label, s) in [
        ("half-hourly, 2 of 48 published", series(halfHoursPublished: 2, halfHourly: true)),
        ("half-hourly, all 48 published", series(halfHoursPublished: 48, halfHourly: true)),
        ("daily meter, day published", series(halfHoursPublished: 1, halfHourly: false)),
    ] {
        print("    \(label): complete=\(s.isComplete)")
    }

    print("  cache freshness:")
    // A week that ended long before it was fetched can't change; one fetched soon after it ended
    // still can, since Octopus corrects costs after publishing them.
    let oldWeek = UsageSeries(from: date("2025-12-01T00:00:00Z"), to: date("2025-12-08T00:00:00Z"))
    let recentWeek = UsageSeries(from: date("2025-12-22T00:00:00Z"), to: date("2025-12-29T00:00:00Z"))
    let settled = CachedUsage(series: oldWeek, fetchedAt: date("2026-01-01T00:00:00Z"), complete: true)
    let unrevised = CachedUsage(series: recentWeek, fetchedAt: date("2026-01-01T00:00:00Z"), complete: true)
    let pending = CachedUsage(series: oldWeek, fetchedAt: date("2026-01-01T00:00:00Z"), complete: false)
    let justNow = CachedUsage(series: UsageSeries(), fetchedAt: Date(), complete: false)
    print("    settled week, fetched months ago: \(settled.isFresh())")
    print("    complete week, fetched 3 days after it ended, months ago: \(unrevised.isFresh())")
    print("    incomplete week, fetched months ago: \(pending.isFresh())")
    print("    incomplete week, fetched just now: \(justNow.isFresh())")
    print("  axis scale (max, step, ticks):")
    for value in [3.9, 2.5, 5.0, 7.4, 39.4, 59.3, 417.0, 0.3, 0.0] {
        let (top, step) = axisScale(value)
        let ticks = stride(from: 0.0, through: top + step / 2, by: step)
            .map { String(format: "%g", $0) }
        print("    \(value) -> max \(String(format: "%g", top)) step \(String(format: "%g", step)): \(ticks.joined(separator: ", "))")
    }

    // What the Settings checkbox says when macOS does not simply agree. The status itself comes
    // from the system, so only the wording is testable here.
    print("  login item advice:")
    for status in [
        SMAppService.Status.enabled, .requiresApproval, .notFound, .notRegistered,
    ] {
        print("    \(LoginItem.describe(status).padding(toLength: 18, withPad: " ", startingAt: 0)): "
            + (LoginItem.advice(for: status) ?? "(nothing to say)"))
    }

    print("  account and tariff sections (single-property account adds no addresses):")
    var oneHouse = snap
    oneHouse.propertyCount = 1
    oneHouse.tariffEnds = [
        TariffEnd(fuel: .electricity, name: "Intelligent Octopus Go", property: "1 Test Lane"),
        TariffEnd(
            fuel: .gas, name: "Octopus 12M Fixed", ends: date("2026-10-08T23:00:00Z"),
            property: "1 Test Lane"),
    ]
    for line in accountLines(oneHouse, now: date("2026-09-19T15:13:00Z"))
        + tariffLines(oneHouse, now: date("2026-09-19T15:13:00Z"))
    {
        switch line {
        case .header(let t): print("    [\(t)]")
        case .text(let t): print("    \(t)")
        case .separator: break
        }
    }

    print("  tariff end wording:")
    for days in [0, 1, 14] {
        var ending = oneHouse
        ending.tariffEnds = [
            TariffEnd(
                fuel: .gas, name: "Octopus 12M Fixed",
                // Cover stops at midnight, so the last covered day is the one before `ends`.
                ends: date("2026-09-19T23:00:00Z").addingTimeInterval(Double(days) * 86400),
                property: "1 Test Lane"),
        ]
        let detail = tariffLines(ending, now: date("2026-09-19T15:13:00Z")).compactMap { line -> String? in
            if case .text(let text) = line, text.hasPrefix("    ") { return text.trimmingCharacters(in: .whitespaces) }
            return nil
        }
        print("    \(days) day\(days == 1 ? "" : "s"): menu \"\(detail.joined())\", alert \"Octopus 12M Fixed ends \(dayCount(days))\"")
    }

    print("  planned charge line:")
    func withPlan(_ slots: [(String, String, Double?, String)]) -> Snapshot {
        var copy = snap
        copy.dispatches = slots.map {
            Interval(start: date($0.0), end: date($0.1), smart: true, plannedKwh: $0.2, chargeType: $0.3)
        }
        return copy
    }
    let atNoon = date("2026-09-19T15:13:00Z")
    for (label, snapshot) in [
        ("one smart slot", withPlan([("2026-09-19T23:30:00Z", "2026-09-20T03:00:00Z", 18.277, "SMART")])),
        ("two slots, summed",
         withPlan([
            ("2026-09-19T23:30:00Z", "2026-09-20T03:00:00Z", 18.277, "SMART"),
            ("2026-09-20T04:30:00Z", "2026-09-20T05:00:00Z", 1.7275, "SMART"),
         ])),
        ("a boost", withPlan([("2026-09-19T20:00:00Z", "2026-09-19T21:00:00Z", 5.2, "BOOST")])),
        // The planner does not always say how much, and a slot with no energy must not print
        // "about 0 kWh".
        ("no energy stated", withPlan([("2026-09-19T23:30:00Z", "2026-09-20T03:00:00Z", nil, "SMART")])),
        ("nothing planned", withPlan([])),
        // Slots already finished are not the plan any more.
        ("only past slots", withPlan([("2026-09-19T06:00:00Z", "2026-09-19T07:00:00Z", 9.0, "SMART")])),
    ] {
        print("    \(label.padding(toLength: 20, withPad: " ", startingAt: 0)): "
            + (plannedChargeLine(snapshot, now: atNoon) ?? "(no line)"))
    }

    // The menu's carbon section: now, and when it is next green. Built from a synthetic forecast
    // of 96 half hours from 15:00Z, with the grams given per half hour by `gramsAt`.
    print("  carbon in the menu:")
    let carbonStart = date("2026-09-19T15:00:00Z")
    func carbonForecast(_ gramsAt: (Int) -> Double) -> [CarbonReading] {
        (0..<96).map { position in
            let from = carbonStart.addingTimeInterval(Double(position) * 1800)
            let grams = gramsAt(position)
            return CarbonReading(
                start: from, end: from.addingTimeInterval(1800), grams: grams,
                index: grams < 100 ? .low : grams < 180 ? .moderate : .high)
        }
    }
    let carbonNow = date("2026-09-19T15:13:00Z")
    for (label, readings) in [
        ("green now, for three hours", carbonForecast { $0 < 6 ? 80 : 150 }),
        ("green later today", carbonForecast { (8..<12).contains($0) ? 90 : 150 }),
        ("green tomorrow", carbonForecast { (40..<44).contains($0) ? 60 : 150 }),
        ("exactly 100 g counts as green", carbonForecast { $0 == 0 ? 100 : 150 }),
        ("never green", carbonForecast { _ in 150 }),
        ("green to the end of the forecast", carbonForecast { _ in 50 }),
        ("no forecast", []),
    ] as [(String, [CarbonReading])] {
        let texts = carbonLines(readings, now: carbonNow, tz: tzLondon).compactMap { line -> String? in
            if case .text(let text) = line { return text }
            return nil
        }
        print("    \(label.padding(toLength: 32, withPad: " ", startingAt: 0)): "
            + (texts.isEmpty ? "(no section)" : texts.joined(separator: " | ")))
    }
    print("    placement, with a forecast:")
    for line in menuLines(snap, now: carbonNow, carbon: carbonForecast { (8..<12).contains($0) ? 90 : 150 }).prefix(14) {
        switch line {
        case .separator: print("      ------")
        case .header(let t): print("      [\(t)]")
        case .text(let t): print("      \(t)")
        }
    }

    // The alert fires in both directions now, so the rule has to name the right one. A merged
    // window must not produce a change in its middle, where nothing actually changes.
    // The icon: shape for carbon, fill (and colour) for the cheap rate, the bolt when carbon is
    // unknown. Each symbol must exist, or the status item falls back to a bare "⚡".
    print("  status icon:")
    for (label, cheap, low) in [
        ("cheap, low carbon", true, Bool?.some(true)), ("cheap, high carbon", true, false),
        ("standard, low carbon", false, true), ("standard, high carbon", false, false),
        ("cheap, carbon unknown", true, nil), ("standard, carbon unknown", false, nil),
    ] {
        let symbol = statusSymbol(cheap: cheap, lowCarbon: low)
        let exists = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        print("    \(label.padding(toLength: 26, withPad: " ", startingAt: 0)): \(symbol)\(exists ? "" : "  <-- MISSING")")
    }
    print("    100 g low=\(carbonIsLow(100)), 101 g low=\(carbonIsLow(101))")
    let greenHalfHour = CarbonReading(
        start: date("2026-09-19T15:00:00Z"), end: date("2026-09-19T15:30:00Z"), grams: 84, index: .low)
    print("    tip: \(statusTip(snap, cheap: true, carbon: greenHalfHour))")
    print("    tip: \(statusTip(snap, cheap: false, carbon: nil))")

    print("  next rate change:")
    let window = [
        Interval(start: date("2026-09-19T22:30:00Z"), end: date("2026-09-20T04:30:00Z"), smart: false),
        Interval(start: date("2026-09-20T12:00:00Z"), end: date("2026-09-20T13:30:00Z"), smart: true),
    ]
    for (label, at) in [
        ("standard, hours before", "2026-09-19T18:00:00Z"),
        ("standard, ten minutes before", "2026-09-19T22:20:00Z"),
        ("inside the cheap window", "2026-09-20T01:00:00Z"),
        ("cheap, ten minutes before it ends", "2026-09-20T04:20:00Z"),
        ("between the window and the dispatch", "2026-09-20T09:00:00Z"),
        ("inside the smart-charge dispatch", "2026-09-20T12:30:00Z"),
        ("after everything", "2026-09-20T20:00:00Z"),
    ] {
        let change = nextRateChange(window, now: date(at))
        let text = change.map {
            "\(formatted($0.at, "EEE HH:mm", tzLondon)) -> \($0.toCheap ? "cheap" : "standard")"
        } ?? "no change ahead"
        print("    \(label.padding(toLength: 36, withPad: " ", startingAt: 0)): \(text)")
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
