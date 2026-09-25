// Grid carbon intensity, from either of two sources that answer the same question.
//
// Octopus carries a forecast on its own API, and National Grid publishes the data Octopus appears
// to relay. They are kept switchable rather than one being chosen, because they differ in ways
// that matter: Octopus gives 24 hours ahead and nothing else, while National Grid gives 48 hours
// ahead, arbitrary history, and the generation mix behind each number — and needs no API key, so
// it costs nothing against the Octopus request budget.

import Foundation

enum CarbonSource: String, CaseIterable {
    case octopus, nationalGrid

    var title: String { self == .octopus ? "Octopus" : "National Grid" }

    /// Octopus only forecasts; National Grid also serves history.
    var supportsHistory: Bool { self == .nationalGrid }

    var needsApiKey: Bool { self == .octopus }
}

/// The five bands both sources use. Octopus spells them `VERY_LOW`, National Grid `very low`.
enum CarbonIndex: String, CaseIterable {
    case veryLow, low, moderate, high, veryHigh

    init?(apiValue: String) {
        let normalised = apiValue.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        switch normalised {
        case "very low": self = .veryLow
        case "low": self = .low
        case "moderate": self = .moderate
        case "high": self = .high
        case "very high": self = .veryHigh
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .veryLow: return "Very low"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .veryHigh: return "Very high"
        }
    }
}

/// What the grid is burning. Named `GridFuel` because `Fuel` is already the meter's fuel.
///
/// **Declaration order is stack order, bottom to top**, and it is also the order of the validated
/// categorical slots — those clear their gates on the *adjacent* pairlist, which for a stack means
/// adjacent in this order. Reordering these silently breaks the colourblind guarantee; re-run
/// `validate_palette.js` if you do. Dirtiest at the bottom, cleanest on top, with the unknown
/// residual underneath everything in neutral grey.
enum GridFuel: String, CaseIterable {
    case other, gas, coal, imports, biomass, nuclear, hydro, wind, solar

    /// National Grid's own spellings. Anything unrecognised folds into `other` rather than being
    /// dropped, or the column would stop totalling 100%.
    init(apiName: String) {
        self = GridFuel(rawValue: apiName.lowercased().trimmingCharacters(in: .whitespaces)) ?? .other
    }

    var title: String {
        switch self {
        case .other: return "Other"
        case .gas: return "Gas"
        case .coal: return "Coal"
        case .imports: return "Imports"
        case .biomass: return "Biomass"
        case .nuclear: return "Nuclear"
        case .hydro: return "Hydro"
        case .wind: return "Wind"
        case .solar: return "Solar"
        }
    }
}

struct FuelShare: Equatable {
    var fuel: GridFuel
    var percent: Double
}

/// What the window is looking at. The default is the forecast; stepping back moves into history a
/// week at a time, which only National Grid can serve.
enum CarbonPeriod: Equatable {
    case forecast
    case week(back: Int)

    var weeksBack: Int? {
        if case .week(let back) = self { return back }
        return nil
    }
}

struct CarbonReading: Equatable {
    var start: Date
    var end: Date
    /// Forecast grams of CO2 per kWh.
    var grams: Double
    var index: CarbonIndex
    /// What the grid is burning, in stack order. National Grid only — Octopus omits it.
    var mix: [FuelShare] = []
    /// GB demand for this half hour in MW: settled outturn in the past, day-ahead forecast in the
    /// near future, and nil beyond where the forecast reaches.
    var demandMW: Double?
    /// Whether `mix` is the national split or the region's. Only the national one can be
    /// multiplied by GB demand to give real megawatts per fuel; the regional one is a proportion
    /// at national scale, which is a weaker claim and has to be labelled as such.
    var mixIsNational = false
}

/// Why a half hour has no demand against it. The two are not the same thing and must not be
/// described the same way: one resolves itself within half an hour, the other is the edge of what
/// has been forecast at all.
enum DemandGap {
    /// Demand is known.
    case none
    /// The half hour is running, or has only just ended. Settled demand is published when a
    /// period ends, and the day-ahead forecast stops covering it once it starts, so for up to
    /// thirty minutes it is covered by neither.
    case stillRunning
    /// Past the end of the day-ahead forecast.
    case beyondForecast
}

/// Bars stand at demand only when enough of the window has it. A couple of settled half hours at
/// the start of a forecast would otherwise leave most of the chart as gaps.
func carbonScaledToDemand(_ readings: [CarbonReading]) -> Bool {
    let known = readings.filter { $0.demandMW != nil }.count
    return known > 0 && known * 2 >= readings.count
}

func demandGap(_ reading: CarbonReading, now: Date) -> DemandGap {
    guard reading.demandMW == nil else { return .none }
    return reading.start <= now ? .stillRunning : .beyondForecast
}

struct CarbonSeries {
    var source: CarbonSource = .nationalGrid
    var period: CarbonPeriod = .forecast
    /// National Grid names the region; Octopus doesn't say.
    var region: String?
    var outward: String = ""
    var readings: [CarbonReading] = []
    var fetchedAt: Date = .distantPast

    var isEmpty: Bool { readings.isEmpty }

    /// Whether the fuel-mix view has anything to draw. Octopus never reports a mix, and a history
    /// range could in principle come back without one.
    var hasMix: Bool { readings.contains { !$0.mix.isEmpty } }

    /// Whether bars can be scaled to demand at all. Without it the mix falls back to percentages.
    var hasDemand: Bool { readings.contains { $0.demandMW != nil } }

    /// Whether the mix view actually stands its bars at demand. The chart and the footer must
    /// agree: the footer used to announce "bars are GB demand" while the chart, short of data,
    /// had quietly fallen back to percentages.
    var scaledToDemand: Bool { carbonScaledToDemand(readings) }

    /// How to describe what the mix segments mean. Up to three bases can appear in one window, in
    /// time order: the national mix for half hours already over, the national forecast for the rest
    /// (National Grid forecasts it for any range spanning now), and the regional forecast share
    /// where the national one wasn't published. Calling a national forecast "actual" — which this
    /// used to do for the whole 48-hour forecast view — claims a measurement that doesn't exist.
    var mixBasis: String {
        let withMix = readings.filter { !$0.mix.isEmpty }
        guard !withMix.isEmpty else { return "no mix" }
        let labels = withMix.map { reading in
            !reading.mixIsNational
                ? "\(region ?? outward) forecast share"
                : reading.end <= fetchedAt ? "GB actual" : "GB forecast"
        }
        // Each basis once, in the order the window meets it.
        var runs: [String] = []
        for label in labels where runs.last != label { runs.append(label) }
        var seen = Set<String>()
        return "mix: " + runs.filter { seen.insert($0).inserted }.joined(separator: ", then ")
    }

    /// Forecasts go stale as the window they cover slides forward. A past week is settled and
    /// worth keeping for the session — it cannot change.
    func isFresh(now: Date = Date(), within: TimeInterval = 30 * 60) -> Bool {
        guard !isEmpty else { return false }
        if let back = period.weeksBack, back > 0 { return true }
        return now.timeIntervalSince(fetchedAt) < within
    }

    /// The cleanest half hour in the window, as the grid operator forecasts it.
    var cleanest: CarbonReading? {
        readings.min { $0.grams < $1.grams }
    }

    /// The period covering `now`, when the series reaches that far.
    func current(_ now: Date = Date()) -> CarbonReading? {
        readings.first { $0.start <= now && now < $0.end }
    }
}

/// Mean share per fuel over a window, for the legend and the footer alike so they can never
/// disagree. Fuels that never appear are absent rather than zero.
func averageMix(_ readings: [CarbonReading]) -> [GridFuel: Double] {
    guard !readings.isEmpty else { return [:] }
    var totals: [GridFuel: Double] = [:]
    for reading in readings {
        for share in reading.mix { totals[share.fuel, default: 0] += share.percent }
    }
    return totals.mapValues { $0 / Double(readings.count) }
}

/// Minute-precision UTC stamps, as National Grid and Elexon write them. Built once; DateFormatter
/// is safe to use from several threads.
private final class MinuteStamp: @unchecked Sendable {
    let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter
    }()
}

private let minuteStamp = MinuteStamp()

/// National Grid stamps periods to the minute — `2026-09-22T17:30Z`, with no seconds — which
/// `ISO8601DateFormatter` rejects under `.withInternetDateTime`. Without this every row parses to
/// nil and the series looks empty rather than broken.
func parseCarbonDate(_ any: Any?) -> Date? {
    guard let text = any as? String else { return nil }
    // The minute form first: it is what National Grid and Elexon send, row after row.
    return minuteStamp.formatter.date(from: text) ?? parseDate(text)
}

/// The outward code — "SN13" from "SN13 9XX". Both APIs take the outward part, and it is all
/// they need: sending the full postcode would pin down a household for no extra accuracy.
func outwardCode(_ postcode: String) -> String {
    let trimmed = postcode.trimmingCharacters(in: .whitespaces).uppercased()
    if let space = trimmed.firstIndex(of: " ") { return String(trimmed[..<space]) }
    // The inward part is always three characters, but only strip it when there is a full
    // postcode to strip it from. An outward code on its own ("SN13") is already the answer, and
    // dropping three off it leaves "S" — which the API rejects.
    return trimmed.count >= 5 ? String(trimmed.dropLast(3)) : trimmed
}

// MARK: - Fetching

func getJSON(_ url: URL) async throws -> [String: Any] {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw ApiError(message: "Carbon intensity service returned \(http.statusCode)")
    }
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ApiError(message: "Unexpected response from the carbon intensity service")
    }
    return body
}

func fetchCarbon(
    source: CarbonSource, period: CarbonPeriod, apiKey: String?, postcode: String, tz: TimeZone
) async throws -> CarbonSeries {
    let outward = outwardCode(postcode)
    guard !outward.isEmpty else { throw ApiError(message: "No postcode for this property") }
    switch source {
    case .octopus:
        guard period == .forecast else {
            throw ApiError(message: "Octopus only forecasts — switch to National Grid for past weeks.")
        }
        guard let apiKey else { throw ApiError(message: "No API key set — add one in Settings.") }
        return try await fetchOctopusCarbon(apiKey: apiKey, postcode: postcode, outward: outward)
    case .nationalGrid:
        return try await fetchNationalGridCarbon(outward: outward, period: period, tz: tz)
    }
}

private func fetchOctopusCarbon(apiKey: String, postcode: String, outward: String) async throws -> CarbonSeries {
    let token = try await OctopusSession.shared.token(apiKey: apiKey)
    let data = try await gql(
        """
        query($p:String!){getProjectedRegionalCarbonIntensity(postcode:$p){
          projectedRegionalCarbonIntensity{periodStart value index}
        }}
        """, ["p": postcode], token: token)
    let rows = ((data["getProjectedRegionalCarbonIntensity"] as? [String: Any])?[
        "projectedRegionalCarbonIntensity"] as? [[String: Any]]) ?? []
    let readings = parseOctopusCarbon(rows)
    guard !readings.isEmpty else {
        throw ApiError(message: "Octopus returned no carbon intensity for \(outward)", invalidatesSession: false)
    }

    return CarbonSeries(
        source: .octopus, region: nil, outward: outward, readings: readings, fetchedAt: Date())
}

/// Octopus states only the period start. The rows are half-hourly, so the end is the next start —
/// and the last row's end has to be assumed rather than dropped, or the final period vanishes.
func parseOctopusCarbon(_ rows: [[String: Any]]) -> [CarbonReading] {
    let parsed: [(Date, Double, CarbonIndex)] = rows.compactMap { row in
        guard
            let start = parseDate(row["periodStart"]),
            let grams = toDouble(row["value"]),
            let index = CarbonIndex(apiValue: row["index"] as? String ?? "")
        else { return nil }
        return (start, grams, index)
    }.sorted { $0.0 < $1.0 }

    return parsed.enumerated().map { position, row in
        let end = position + 1 < parsed.count
            ? parsed[position + 1].0 : row.0.addingTimeInterval(30 * 60)
        return CarbonReading(start: row.0, end: end, grams: row.1, index: row.2)
    }
}

/// The regional intensity alone, in one keyless request: what the menu bar icon needs, without the
/// demand and national-mix calls the carbon window adds. Returns the region's name and the
/// readings, trimmed to the window asked for.
func fetchRegionalReadings(
    outward: String, period: CarbonPeriod, tz: TimeZone
) async throws -> (region: String?, readings: [CarbonReading]) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"

    let tail: String
    // The window actually asked for, kept so the reply can be trimmed back to it.
    let windowStart: Date
    let windowEnd: Date
    switch period {
    case .forecast:
        // Start on the half hour so the returned periods line up with the grid's own slots.
        let now = Date()
        let slot = Date(
            timeIntervalSince1970: (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
        windowStart = slot
        windowEnd = slot.addingTimeInterval(48 * 3600)
        tail = "\(formatter.string(from: slot))/fw48h"
    case .week(let back):
        // The same window the usage charts use, so a week means the same thing in both.
        // A seven-day range returns all 336 half hours in one request — it is not capped.
        let window = usageDateWindow(weeksBack: back, days: 7, tz: tz)
        windowStart = window.from
        windowEnd = window.to
        tail = "\(formatter.string(from: window.from))/\(formatter.string(from: window.to))"
    }

    let escaped = outward.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? outward
    guard
        let url = URL(
            string: "https://api.carbonintensity.org.uk/regional/intensity/\(tail)/postcode/\(escaped)")
    else { throw ApiError(message: "Couldn't build the carbon intensity request") }

    let body = try await getJSON(url)
    // The forward-forecast endpoint returns an object; the current-period one returns an array of
    // them. Accept both, so a change of endpoint doesn't need this parsing rewritten.
    let region: [String: Any]?
    if let object = body["data"] as? [String: Any] {
        region = object
    } else {
        region = (body["data"] as? [[String: Any]])?.first
    }
    guard let region else { throw ApiError(message: "No carbon intensity for \(outward)") }
    // National Grid includes the period *ending* at the requested start, so a week asked for from
    // local midnight came back with the 23:30–00:00 half hour of the day before — a bar outside
    // the range the window's own label claims, and 337 half hours where a week has 336.
    let readings = parseNationalGridCarbon(region["data"] as? [[String: Any]] ?? [])
        .filter { $0.start >= windowStart && $0.start < windowEnd }
    guard !readings.isEmpty else {
        throw ApiError(message: "National Grid returned no carbon intensity for \(outward)")
    }
    return (region["shortname"] as? String, readings)
}

private func fetchNationalGridCarbon(
    outward: String, period: CarbonPeriod, tz: TimeZone
) async throws -> CarbonSeries {
    var (regionName, readings) = try await fetchRegionalReadings(outward: outward, period: period, tz: tz)

    // Demand and the national mix are national and keyless. Fetched together — neither blocks
    // the other, and both are optional garnish on the intensity view.
    if let first = readings.first, let last = readings.last {
        async let demand = fetchGBDemand(from: first.start, to: last.end)
        async let national = fetchNationalMix(from: first.start, to: last.end)
        let (demandBySlot, nationalBySlot) = await (demand, national)
        readings = readings.map { reading in
            var updated = reading
            let key = Int(reading.start.timeIntervalSince1970 / 1800)
            updated.demandMW = demandBySlot[key]
            // The national split is the only one that can be multiplied by GB demand to mean
            // megawatts. Where it hasn't been published the regional forecast stands in, and
            // the flag records which so the chart can say so.
            if let shares = nationalBySlot[key] {
                updated.mix = shares
                updated.mixIsNational = true
            }
            return updated
        }
    }

    return CarbonSeries(
        source: .nationalGrid, period: period, region: regionName,
        outward: outward, readings: readings, fetchedAt: Date())
}

// MARK: - GB demand and the national mix
//
// Both are national, and neither needs a key. They are fetched alongside the regional intensity
// so the fuel-mix view can stand bars at their real height rather than a flat 100%.

/// Half-hourly slots keyed to the second, so three sources can be joined by period start.
private func slotKey(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 1800) }

/// Elexon numbers settlement periods from *local* midnight, half hour by half hour, and dates a
/// settlement day by its local date. Used only to name a period when asking which publication
/// covers it, so the two long days a year do not matter: a neighbouring period identifies the
/// same publication.
private func settlementRef(_ date: Date) -> (date: String, period: Int) {
    let london = TimeZone(identifier: "Europe/London") ?? .current
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = london
    let midnight = cal.startOfDay(for: date)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = london
    formatter.dateFormat = "yyyy-MM-dd"
    return (formatter.string(from: midnight), Int(date.timeIntervalSince(midnight) / 1800) + 1)
}

/// GB demand in MW per half hour: settled outturn for the past, day-ahead forecast for the near
/// future. Both are asked for every time — a window can straddle now, and neither covers the
/// other's half.
func fetchGBDemand(from: Date, to: Date) async -> [Int: Double] {
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.timeZone = TimeZone(identifier: "UTC")
    iso.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC")
    day.dateFormat = "yyyy-MM-dd"

    let base = "https://data.elexon.co.uk/bmrs/api/v1"
    var demand: [Int: Double] = [:]

    /// Takes a response's rows, keeping the first value seen for each slot. Everything here is
    /// loaded newest-first, so the first value is the freshest.
    @discardableResult
    func absorb(_ body: [String: Any], field: String) -> Int {
        var added = 0
        for row in body["data"] as? [[String: Any]] ?? [] {
            guard let start = parseCarbonDate(row["startTime"]), let value = toDouble(row[field])
            else { continue }
            let key = slotKey(start)
            if demand[key] == nil {
                demand[key] = value
                added += 1
            }
        }
        return added
    }

    /// Demand is a garnish on the mix view — a failure leaves the bars unscaled rather than
    /// failing the whole window — so nothing here throws.
    func fetch(_ endpoint: String) async -> [String: Any]? {
        guard let url = URL(string: endpoint) else { return nil }
        return try? await getJSON(url)
    }

    // Settled demand first: it is measurement, and a forecast must never overwrite it.
    if let body = await fetch(
        "\(base)/demand/outturn?settlementDateFrom=\(day.string(from: from))"
            + "&settlementDateTo=\(day.string(from: to))&format=json")
    {
        absorb(body, field: "initialDemandOutturn")
    }

    let now = Date()
    // A window that ends in the past is fully settled; there is nothing for a forecast to add.
    guard to > now else { return demand }
    // From the *next* half hour, not this one. The period in progress is covered by neither the
    // settled outturn nor any live forecast, so hunting for a publication to fill it burns a
    // round of lookups on a hole that is structural.
    let firstSlot = slotKey(now) + 1
    let lastSlot = slotKey(to.addingTimeInterval(-1))
    guard firstSlot <= lastSlot else { return demand }
    let slots = firstSlot...lastSlot

    // The national demand forecast is republished every half hour, and each publication is its
    // own block: usually an intraday update covering the rest of today, and once a day the
    // day-ahead issue covering tomorrow. `/forecast/demand/day-ahead` returns only the *newest*
    // publication and ignores from/to when selecting it, so it alone can never cover 48 hours.
    // Walking back one publication at a time does not work either — by mid-morning the day-ahead
    // issue is already several intraday updates back, and by evening it is dozens.
    //
    // So: take the newest publication, then *ask* which publication covers the first half hour
    // still missing. /evolution names it, and /history then fetches that whole block. Two calls
    // per block, and no guessing at publication times.
    if let body = await fetch("\(base)/forecast/demand/day-ahead/history"
        + "?publishTime=\(iso.string(from: now))&format=json")
    {
        absorb(body, field: "nationalDemand")
    }

    for _ in 0..<2 {
        guard let missing = slots.first(where: { demand[$0] == nil }) else { break }
        let ref = settlementRef(Date(timeIntervalSince1970: Double(missing) * 1800))
        guard
            let evolution = await fetch(
                "\(base)/forecast/demand/day-ahead/evolution"
                    + "?settlementDate=\(ref.date)&settlementPeriod=\(ref.period)&format=json"),
            let rows = evolution["data"] as? [[String: Any]],
            let newest = rows.compactMap({ parseCarbonDate($0["publishTime"]) }).max(),
            let block = await fetch("\(base)/forecast/demand/day-ahead/history"
                + "?publishTime=\(iso.string(from: newest))&format=json"),
            absorb(block, field: "nationalDemand") > 0
        else { break }
    }
    return demand
}

/// The GB generation mix per half hour. A range spanning now comes back whole, forecast included;
/// only a range whose *start* is in the future silently clamps to the last published half hour.
/// Where a slot is missing, the regional forecast split stands in, and `mixBasis` says which.
func fetchNationalMix(from: Date, to: Date) async -> [Int: [FuelShare]] {
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.timeZone = TimeZone(identifier: "UTC")
    iso.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
    guard
        let url = URL(
            string: "https://api.carbonintensity.org.uk/generation/"
                + "\(iso.string(from: from))/\(iso.string(from: to))"),
        let body = try? await getJSON(url)
    else { return [:] }

    var mixes: [Int: [FuelShare]] = [:]
    for row in body["data"] as? [[String: Any]] ?? [] {
        guard let start = parseCarbonDate(row["from"]) else { continue }
        let shares = parseMix(row["generationmix"] as? [[String: Any]] ?? [])
        guard !shares.isEmpty else { continue }
        mixes[slotKey(start)] = shares
    }
    return mixes
}

/// Merges a generation mix into stack order, folding anything unrecognised into `other`.
/// Shared by the regional and national parsers so both produce the same shape.
func parseMix(_ entries: [[String: Any]]) -> [FuelShare] {
    var shares: [GridFuel: Double] = [:]
    for entry in entries {
        guard let name = entry["fuel"] as? String, let percent = toDouble(entry["perc"]), percent > 0
        else { continue }
        shares[GridFuel(apiName: name), default: 0] += percent
    }
    // Stack order, not descending share: the palette's colourblind guarantee holds for
    // neighbours in this order.
    return GridFuel.allCases.compactMap { fuel in
        shares[fuel].map { FuelShare(fuel: fuel, percent: $0) }
    }
}

func parseNationalGridCarbon(_ rows: [[String: Any]]) -> [CarbonReading] {
    rows.compactMap { row -> CarbonReading? in
        let intensity = row["intensity"] as? [String: Any] ?? [:]
        guard
            let start = parseCarbonDate(row["from"]), let end = parseCarbonDate(row["to"]),
            // Past periods carry `actual`; future ones only `forecast`.
            let grams = toDouble(intensity["actual"]) ?? toDouble(intensity["forecast"]),
            let index = CarbonIndex(apiValue: intensity["index"] as? String ?? "")
        else { return nil }
        let mix = parseMix(row["generationmix"] as? [[String: Any]] ?? [])
        return CarbonReading(start: start, end: end, grams: grams, index: index, mix: mix)
    }
    .sorted { $0.start < $1.start }
}
