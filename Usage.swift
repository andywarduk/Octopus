// A week of half-hourly electricity use, split by which tariff band actually charged it.
//
// Every interval lists all four of the tariff's buckets; only the one with kWh against it was
// charged. Amounts come back in pence even though costCurrency says GBP.

import Foundation

/// Declaration order is the stack order, bottom to top: standard sits underneath, so the
/// off-peak block on top is easy to compare night to night. Bands are prices, which are real. The tariff's per-device buckets
/// are NOT a measurement of what each device drew — Octopus allocates a fixed amount to the EV
/// bucket and the rest of the car's draw lands in the household bucket at the same price — so a
/// dispatch is flagged on the period instead of being split out as its own band.
enum RateBand: String, CaseIterable {
    case standard = "Standard"
    case cheap = "Off-peak"
}

/// One charged bucket within one half hour.
struct UsageBucket {
    var start: Date
    var label: String
    var kwh: Double
    var pence: Double
    var pricePerUnit: Double
}

enum Granularity {
    case day, halfHour
}

/// One column: a day or a single half hour, split by band.
struct UsagePeriod {
    var start: Date
    var end: Date
    var kwh: [RateBand: Double] = [:]
    var pence: [RateBand: Double] = [:]
    var standingPence: Double = 0
    /// Some of this period was billed against an EV device bucket, i.e. a smart charge ran.
    var smartCharge = false
    /// The API returned something for this period. False means not published yet, which is not
    /// the same as having used nothing — Octopus runs roughly two days behind.
    var hasData = false

    func value(_ band: RateBand, _ unit: UsageUnit) -> Double {
        (unit == .kwh ? kwh[band] : pence[band]) ?? 0
    }

    func total(_ unit: UsageUnit) -> Double {
        RateBand.allCases.reduce(0) { $0 + value($1, unit) }
    }

    /// Averaged over the band's own energy, so it reads as the price actually charged.
    func price(_ band: RateBand) -> Double? {
        let energy = kwh[band] ?? 0
        guard energy >= 0.001, let cost = pence[band] else { return nil }
        return cost / energy
    }
}

enum UsageUnit {
    case kwh, money
}

/// Splits the prices seen into cheap and standard. Nil when the tariff has a single rate.
func priceThreshold(_ buckets: [UsageBucket]) -> Double? {
    let prices = buckets.map(\.pricePerUnit).filter { $0 > 0 }
    guard let low = prices.min(), let high = prices.max() else { return nil }
    guard high - low >= max(1.0, low * 0.2) else { return nil }
    return (low + high) / 2
}

func band(for bucket: UsageBucket, threshold: Double?) -> RateBand {
    guard let threshold, bucket.pricePerUnit < threshold else { return .standard }
    return .cheap
}

/// A bucket Octopus bills a smart-charge dispatch against.
func isSmartChargeBucket(_ label: String) -> Bool { label.contains("EV_DEVICE") }

/// Everything one fetch returns, so either granularity can be built without asking again.
struct UsageSeries {
    var buckets: [UsageBucket] = []
    var standing: [(start: Date, pence: Double)] = []
    var tz: TimeZone = .current
    /// The span asked for, so a period the API returned nothing for still gets a column.
    var from: Date?
    var to: Date?
    /// Taken from the readings: electricity is kWh, gas may be cubic metres.
    var energyLabel = "kWh"
    /// False when the meter only reports daily, so the half-hour view has nothing to show.
    var supportsHalfHour = true
    /// Readings returned, whatever they totalled. A meter that used nothing still reports.
    var readings = 0

    /// Zero consumption is data, so emptiness is about readings rather than usage.
    var isEmpty: Bool { readings == 0 }

    func periods(_ granularity: Granularity) -> [UsagePeriod] {
        aggregateUsage(
            buckets, standing: standing, tz: tz, by: granularity,
            window: from.flatMap { start in to.map { (start, $0) } })
    }
}

/// Groups buckets into columns, oldest first. `standing` is per half hour, so it sums per period.
func aggregateUsage(
    _ buckets: [UsageBucket], standing: [(start: Date, pence: Double)], tz: TimeZone,
    by granularity: Granularity = .day, window: (from: Date, to: Date)? = nil
) -> [UsagePeriod] {
    let cal = calendar(tz)
    let threshold = priceThreshold(buckets)

    func bounds(_ instant: Date) -> (start: Date, end: Date) {
        switch granularity {
        case .day:
            let start = cal.startOfDay(for: instant)
            return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
        case .halfHour:
            // Measurements already arrive on half-hour boundaries, so the instant is the key.
            return (instant, instant.addingTimeInterval(1800))
        }
    }

    var periods: [Date: UsagePeriod] = [:]
    // Seed the whole requested span first. Without this a day Octopus hasn't published yet just
    // disappears and the axis closes up, so missing data looks the same as no usage.
    if let window {
        var cursor = bounds(window.from).start
        while cursor < window.to {
            let (start, end) = bounds(cursor)
            periods[start] = UsagePeriod(start: start, end: end)
            switch granularity {
            case .day: cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? end
            case .halfHour: cursor = end
            }
        }
    }
    for bucket in buckets {
        let (start, end) = bounds(bucket.start)
        var entry = periods[start] ?? UsagePeriod(start: start, end: end)
        let slot = band(for: bucket, threshold: threshold)
        entry.kwh[slot, default: 0] += bucket.kwh
        entry.pence[slot, default: 0] += bucket.pence
        if isSmartChargeBucket(bucket.label) { entry.smartCharge = true }
        entry.hasData = true
        periods[start] = entry
    }
    for charge in standing {
        let (start, end) = bounds(charge.start)
        var entry = periods[start] ?? UsagePeriod(start: start, end: end)
        entry.standingPence += charge.pence
        entry.hasData = true
        periods[start] = entry
    }
    return periods.values.sorted { $0.start < $1.start }
}

/// A fetched week, with enough context to know when it is worth keeping.
struct CachedUsage {
    var series: UsageSeries
    var fetchedAt: Date
    /// Every day in the window came back with data, so it can no longer change.
    var complete: Bool

    /// A settled week is kept indefinitely. One still waiting on Octopus is re-checked, since
    /// the missing days appear later.
    func isFresh(now: Date = Date()) -> Bool {
        complete || now.timeIntervalSince(fetchedAt) < 15 * 60
    }
}

// MARK: - Fetching

/// Which reading frequencies to try, finest first. Many gas meters only report daily.
let readingFrequencies = ["THIRTY_MIN_INTERVAL", "DAY_INTERVAL"]

/// GraphQL can parameterise values but not which input field to use, so the filter is built per fuel.
func measurementsQuery(for fuel: Fuel) -> String {
    let filter =
        fuel == .electricity
        ? "electricityFilters:{readingFrequencyType:$freq,marketSupplyPointId:$sp,readingDirection:CONSUMPTION}"
        : "gasFilters:{readingFrequencyType:$freq,marketSupplyPointId:$sp}"
    return """
        query($p:ID!,$s:DateTime!,$e:DateTime!,$sp:String!,$tz:String!,$n:Int!,$freq:ReadingFrequencyType!){
          property(id:$p){
            measurements(startAt:$s,endAt:$e,timezone:$tz,first:$n,utilityFilters:[{\(filter)}]){
              edges{node{
                value
                unit
                ... on IntervalMeasurementType{startAt}
                metaData{statistics{type label value costInclTax{estimatedAmount pricePerUnit{amount}}}}
              }}
            }
          }
        }
        """
}

/// The local window shown for a week offset: 0 is the week ending today, 1 the week before.
func usageDateWindow(weeksBack: Int, days: Int, tz: TimeZone) -> (from: Date, to: Date) {
    let cal = calendar(tz)
    let today = cal.startOfDay(for: Date())
    let lastDay = cal.date(byAdding: .day, value: -7 * weeksBack, to: today) ?? today
    let from = cal.date(byAdding: .day, value: -(days - 1), to: lastDay) ?? lastDay
    return (from, cal.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
}

/// Pulls `days` local days, a day per request, ending `weeksBack` weeks before today.
func fetchUsage(apiKey: String, days: Int, weeksBack: Int = 0, fuel: Fuel = .electricity) async throws
    -> UsageSeries
{
    let auth = try await gql(
        "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": apiKey])
    guard let token = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String else {
        throw ApiError(message: "Login failed")
    }
    let choices = try await discoverMeters(token: token)
    guard let choice = MeterPreference.resolve(from: choices, fuel: fuel) else {
        throw ApiError(message: "No \(fuel.title.lowercased()) meter found on this account")
    }
    let account = choice.accountNumber
    let supplyPoint = choice.supplyPoint
    let propertyId = choice.propertyId

    // Only electricity carries a time-of-use scheme; gas takes the account's own timezone.
    var tzName = "Europe/London"
    if fuel == .electricity {
        let detail = try await gql(
            """
            query($a:String!){account(accountNumber:$a){
              electricityAgreements(active:true){
                meterPoint{mpan}
                timeOfUseScheme{timezone}
              }
            }}
            """, ["a": account], token: token)
        let acc = detail["account"] as? [String: Any] ?? [:]
        let agreement = ((acc["electricityAgreements"] as? [[String: Any]]) ?? []).first {
            ($0["meterPoint"] as? [String: Any])?["mpan"] as? String == supplyPoint
        }
        tzName = ((agreement?["timeOfUseScheme"] as? [String: Any])?["timezone"] as? String) ?? tzName
    }
    let tz = TimeZone(identifier: tzName) ?? TimeZone(identifier: "Europe/London")!
    let cal = calendar(tz)
    let iso = ISO8601DateFormatter()
    iso.timeZone = tz
    iso.formatOptions = [.withInternetDateTime]

    let window = usageDateWindow(weeksBack: weeksBack, days: days, tz: tz)
    let windowStart = window.from
    let windowEnd = window.to
    let query = measurementsQuery(for: fuel)

    /// One pass over the window at a given reading frequency.
    func collect(_ frequency: String) async throws -> (
        buckets: [UsageBucket], standing: [(start: Date, pence: Double)], unit: String?, readings: Int
    ) {
        var buckets: [UsageBucket] = []
        var standing: [(start: Date, pence: Double)] = []
        var unit: String?
        var readings = 0
        for index in 0..<days {
            guard
                let dayStart = cal.date(byAdding: .day, value: index, to: windowStart),
                let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart),
                dayStart < windowEnd
            else { continue }
            let data = try await gql(
                query,
                [
                    "p": propertyId, "sp": supplyPoint, "tz": tzName, "n": 48, "freq": frequency,
                    "s": iso.string(from: dayStart), "e": iso.string(from: dayEnd),
                ], token: token)
            let edges = (((data["property"] as? [String: Any])?["measurements"] as? [String: Any])?["edges"]
                as? [[String: Any]]) ?? []
            for edge in edges {
                guard
                    let node = edge["node"] as? [String: Any],
                    let began = parseDate(node["startAt"])
                else { continue }
                readings += 1
                if unit == nil { unit = node["unit"] as? String }
                let stats = ((node["metaData"] as? [String: Any])?["statistics"] as? [[String: Any]]) ?? []
                let consumption = stats.filter { ($0["type"] as? String) == "CONSUMPTION_COST" }
                // Electricity splits the interval across tariff buckets and puts the kWh on each.
                // Gas has a single bucket whose value is null, so the energy is the reading itself.
                let readingValue = toDouble(node["value"]) ?? 0
                for stat in stats {
                    let money = stat["costInclTax"] as? [String: Any] ?? [:]
                    let amount = toDouble(money["estimatedAmount"]) ?? 0
                    if (stat["type"] as? String) == "STANDING_CHARGE_COST" {
                        standing.append((began, amount))
                        continue
                    }
                    guard (stat["type"] as? String) == "CONSUMPTION_COST" else { continue }
                    // Only fall back to the reading when one bucket covers the whole interval,
                    // otherwise every bucket would claim all of it.
                    let energy = toDouble(stat["value"]) ?? (consumption.count == 1 ? readingValue : 0)
                    guard energy > 0 else { continue }
                    // Gas quotes no unit price, so derive it from what the interval cost.
                    let quoted = toDouble((money["pricePerUnit"] as? [String: Any])?["amount"])
                    buckets.append(
                        UsageBucket(
                            start: began,
                            label: stat["label"] as? String ?? "",
                            kwh: energy,
                            pence: amount,
                            pricePerUnit: quoted ?? (amount / energy)))
                }
            }
        }
        return (buckets, standing, unit, readings)
    }

    // Half-hourly first; a meter that only reports daily returns nothing at all, so fall back.
    // The test is readings, not usage: a meter that consumed nothing still reports zeros.
    var result = try await collect(readingFrequencies[0])
    var supportsHalfHour = true
    if result.readings == 0 {
        result = try await collect(readingFrequencies[1])
        supportsHalfHour = false
    }

    guard result.readings > 0 else {
        throw ApiError(
            message: "No \(fuel.title.lowercased()) readings for \(choice.label). "
                + "Octopus publishes about two days behind, and a meter with no readings stays empty.")
    }
    // "kwh" from the API reads better as "kWh"; anything else (m3) is shown as given.
    let label = (result.unit?.lowercased() == "kwh" ? "kWh" : result.unit) ?? fuel.defaultEnergyLabel
    return UsageSeries(
        buckets: result.buckets, standing: result.standing, tz: tz, from: windowStart, to: windowEnd,
        energyLabel: label, supportsHalfHour: supportsHalfHour, readings: result.readings)
}
