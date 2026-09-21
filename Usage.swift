// A week of half-hourly electricity use, split by which tariff band actually charged it.
//
// Every interval lists all four of the tariff's buckets; only the one with kWh against it was
// charged. Amounts come back in pence even though costCurrency says GBP.

import Foundation

/// Stack order, bottom to top. Bands are prices, which are real. The tariff's per-device buckets
/// are NOT a measurement of what each device drew — Octopus allocates a fixed amount to the EV
/// bucket and the rest of the car's draw lands in the household bucket at the same price — so a
/// dispatch is flagged on the period instead of being split out as its own band.
enum RateBand: String, CaseIterable {
    case cheap = "Off-peak"
    case standard = "Standard"
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

    var isEmpty: Bool { buckets.isEmpty }

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

// MARK: - Fetching

let MEASUREMENTS_QUERY = """
    query($p:ID!,$s:DateTime!,$e:DateTime!,$mpan:String!,$tz:String!,$n:Int!){
      property(id:$p){
        measurements(startAt:$s,endAt:$e,timezone:$tz,first:$n,
          utilityFilters:[{electricityFilters:{readingFrequencyType:THIRTY_MIN_INTERVAL,marketSupplyPointId:$mpan,readingDirection:CONSUMPTION}}]){
          edges{node{
            value
            ... on IntervalMeasurementType{startAt}
            metaData{statistics{type label value costInclTax{estimatedAmount pricePerUnit{amount}}}}
          }}
        }
      }
    }
    """

/// Pulls `days` local days up to the end of today, a day per request.
func fetchUsage(apiKey: String, days: Int) async throws -> UsageSeries {
    let auth = try await gql(
        "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": apiKey])
    guard let token = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String else {
        throw ApiError(message: "Login failed")
    }
    let who = try await gql("{viewer{accounts{number}}}", token: token)
    guard
        let accounts = (who["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]],
        let account = accounts.first?["number"] as? String
    else { throw ApiError(message: "No account found") }

    let detail = try await gql(
        """
        query($a:String!){account(accountNumber:$a){
          properties{id}
          electricityAgreements(active:true){
            meterPoint{mpan direction}
            timeOfUseScheme{timezone}
          }
        }}
        """, ["a": account], token: token)
    let acc = detail["account"] as? [String: Any] ?? [:]
    let agreements = (acc["electricityAgreements"] as? [[String: Any]]) ?? []
    let imports = agreements.filter {
        (($0["meterPoint"] as? [String: Any])?["direction"] as? String)?.uppercased() != "EXPORT"
    }
    guard
        let agreement = imports.first,
        let mpan = (agreement["meterPoint"] as? [String: Any])?["mpan"] as? String,
        let propertyId = (acc["properties"] as? [[String: Any]])?.first?["id"] as? String
    else { throw ApiError(message: "No electricity import meter found") }

    let tzName = ((agreement["timeOfUseScheme"] as? [String: Any])?["timezone"] as? String) ?? "Europe/London"
    let tz = TimeZone(identifier: tzName) ?? TimeZone(identifier: "Europe/London")!
    let cal = calendar(tz)
    let iso = ISO8601DateFormatter()
    iso.timeZone = tz
    iso.formatOptions = [.withInternetDateTime]

    var buckets: [UsageBucket] = []
    var standing: [(start: Date, pence: Double)] = []
    let today = cal.startOfDay(for: Date())
    let windowStart = cal.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    let windowEnd = cal.date(byAdding: .day, value: 1, to: today) ?? today

    for offset in stride(from: days - 1, through: 0, by: -1) {
        guard
            let dayStart = cal.date(byAdding: .day, value: -offset, to: today),
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)
        else { continue }
        let data = try await gql(
            MEASUREMENTS_QUERY,
            [
                "p": propertyId, "mpan": mpan, "tz": tzName, "n": 48,
                "s": iso.string(from: dayStart), "e": iso.string(from: dayEnd),
            ], token: token)
        let edges = (((data["property"] as? [String: Any])?["measurements"] as? [String: Any])?["edges"]
            as? [[String: Any]]) ?? []
        for edge in edges {
            guard
                let node = edge["node"] as? [String: Any],
                let began = parseDate(node["startAt"])
            else { continue }
            let stats = ((node["metaData"] as? [String: Any])?["statistics"] as? [[String: Any]]) ?? []
            for stat in stats {
                let money = stat["costInclTax"] as? [String: Any] ?? [:]
                let amount = toDouble(money["estimatedAmount"]) ?? 0
                if (stat["type"] as? String) == "STANDING_CHARGE_COST" {
                    standing.append((began, amount))
                    continue
                }
                guard (stat["type"] as? String) == "CONSUMPTION_COST" else { continue }
                let kwh = toDouble(stat["value"]) ?? 0
                guard kwh > 0 else { continue }
                buckets.append(
                    UsageBucket(
                        start: began,
                        label: stat["label"] as? String ?? "",
                        kwh: kwh,
                        pence: amount,
                        pricePerUnit: toDouble((money["pricePerUnit"] as? [String: Any])?["amount"]) ?? 0))
            }
        }
    }
    guard !buckets.isEmpty else { throw ApiError(message: "No half-hourly usage came back for this period.") }
    return UsageSeries(buckets: buckets, standing: standing, tz: tz, from: windowStart, to: windowEnd)
}
