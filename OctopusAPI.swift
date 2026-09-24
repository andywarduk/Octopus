// Octopus GraphQL API: obtain a token from the API key, then fetch tariff, schedule and cars.

import Foundation

struct ApiError: Error, LocalizedError {
    let message: String
    /// Whether the failure casts doubt on the cached token and meters. An answer that is simply
    /// empty — a week not yet published — says nothing about either, and dropping them would make
    /// the next attempt log in and rediscover for no reason.
    var invalidatesSession = true
    var errorDescription: String? { message }
}

/// Drops the cached token and meters unless the error is known not to concern them.
func invalidateSession(after error: Error) async {
    if (error as? ApiError)?.invalidatesSession == false { return }
    await OctopusSession.shared.invalidate()
}

func toDouble(_ any: Any?) -> Double? {
    if let s = any as? String { return Double(s) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}

/// Built once: a week of carbon readings parses over a thousand timestamps, and constructing a
/// formatter per call dominated that. ISO8601DateFormatter is thread-safe once configured.
private final class ISOParsers: @unchecked Sendable {
    let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private let isoParsers = ISOParsers()

func parseDate(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    return isoParsers.fractional.date(from: s) ?? isoParsers.whole.date(from: s)
}

func minutes(_ hhmmss: String) -> Int? {
    let p = hhmmss.split(separator: ":").compactMap { Int($0) }
    return p.count >= 2 ? p[0] * 60 + p[1] : nil
}

func gql(_ query: String, _ variables: [String: Any] = [:], token: String? = nil) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api.octopus.energy/v1/graphql/")!, timeoutInterval: 30)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
    // A GraphQL error can arrive under a 4xx and says more than the status does, so it goes first.
    // A rate limit or an outage usually has no JSON body at all, and parsing it would report a
    // format error that hides the real cause.
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if let errors = body?["errors"] as? [[String: Any]], let first = errors.first {
        throw ApiError(message: first["message"] as? String ?? "GraphQL error")
    }
    guard (200..<300).contains(status) else {
        throw ApiError(message: status == 429 ? "Octopus is rate-limiting requests (HTTP 429)" : "Octopus returned HTTP \(status)")
    }
    guard let body else { throw ApiError(message: "Unexpected response") }
    return body["data"] as? [String: Any] ?? [:]
}

/// What refreshes can reuse from one another: the Kraken token, the discovered meters, the tariff
/// and the smart device ids.
///
/// Each refresh used to log in afresh, rediscover every meter and refetch the tariff — five of its
/// six requests, every five minutes, spent re-learning things that change about never. A token
/// lasts an hour, so it is kept for 45 minutes; meters for an hour. Any failure drops everything,
/// so a revoked token or a changed account is picked up on the very next attempt rather than after
/// the timeout.
actor OctopusSession {
    static let shared = OctopusSession()

    private static let tokenLifetime: TimeInterval = 45 * 60
    private static let meterLifetime: TimeInterval = 60 * 60

    private var apiKey: String?
    private var token: (value: String, at: Date)?
    private var meters: (value: [MeterChoice], at: Date)?
    /// The tariff half of the last snapshot. Whether it is still usable is `tariffIsReusable`'s call.
    private(set) var tariff: TariffState?
    /// Smart device ids per account, as last seen, so the charge plan can be asked for alongside the
    /// device list instead of after it.
    private var devices: [String: [String]] = [:]

    func setTariff(_ state: TariffState) { tariff = state }

    func deviceIds(account: String) -> [String] { devices[account] ?? [] }

    func setDeviceIds(_ ids: [String], account: String) { devices[account] = ids }

    func token(apiKey key: String) async throws -> String {
        forgetIfKeyChanged(key)
        if let token, Date().timeIntervalSince(token.at) < Self.tokenLifetime { return token.value }
        let auth = try await gql(
            "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": key])
        guard let value = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String else {
            throw ApiError(message: "Login failed")
        }
        // The key may have changed while this was awaiting; don't file a token under the wrong one.
        if apiKey == key { token = (value, Date()) }
        return value
    }

    func meters(apiKey key: String) async throws -> [MeterChoice] {
        forgetIfKeyChanged(key)
        if let meters, Date().timeIntervalSince(meters.at) < Self.meterLifetime { return meters.value }
        let found = try await discoverMeters(token: token(apiKey: key))
        if apiKey == key { meters = (found, Date()) }
        return found
    }

    /// Called after any failed request: whatever went wrong, the next attempt starts clean.
    func invalidate() {
        token = nil
        meters = nil
        tariff = nil
        devices = [:]
    }

    private func forgetIfKeyChanged(_ key: String) {
        guard key != apiKey else { return }
        apiKey = key
        invalidate()
    }
}

let fallbackWindows = [(from: 23 * 60 + 30, to: 5 * 60 + 30)]

/// Every active agreement on the account, one entry per meter point, never merged.
///
/// Includes variable tariffs, which have no `validTo` — Intelligent Octopus Go is one, and it is
/// the very tariff the menu bar's prices come from, so leaving it out made the menu silent about
/// it. Two houses on the same tariff stay two entries: the list is what the account holds. Takes
/// the raw `account` node so it can be exercised without the network.
func parseTariffEnds(_ account: [String: Any], now: Date) -> [TariffEnd] {
    var found: [TariffEnd] = []
    for property in (account["properties"] as? [[String: Any]]) ?? [] {
        // The first line of the address, as the meter picker shows it.
        let address = property["address"] as? String ?? ""
        let place = address.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        for (field, fuel) in [("electricityMeterPoints", Fuel.electricity), ("gasMeterPoints", .gas)] {
            for point in (property[field] as? [[String: Any]]) ?? [] {
                for agreement in (point["agreements"] as? [[String: Any]]) ?? [] {
                    let ends = parseDate(agreement["validTo"])
                    guard
                        agreement["isRevoked"] as? Bool != true,
                        // Already over, or not started yet — the latter is the replacement
                        // waiting to take over, not something in force.
                        ends.map({ $0 > now }) ?? true,
                        parseDate(agreement["validFrom"]).map({ $0 <= now }) ?? true
                    else { continue }
                    let name = (agreement["tariff"] as? [String: Any])?["displayName"] as? String
                    found.append(
                        TariffEnd(
                            fuel: fuel, name: name ?? "\(fuel.title) tariff", ends: ends,
                            property: place))
                }
            }
        }
    }
    // Soonest expiry first, with the never-ending ones last; then by address so a property's
    // agreements sit together.
    return found.sorted {
        switch ($0.ends, $1.ends) {
        case let (a?, b?) where a != b: return a < b
        case (nil, _?): return false
        case (_?, nil): return true
        default: return ($0.property, $0.fuel.rawValue) < ($1.property, $1.fuel.rawValue)
        }
    }
}

/// How many distinct addresses the account holds, so a tariff covering all of them needs no
/// naming and one covering a single address does.
func propertyCount(_ account: [String: Any]) -> Int {
    (account["properties"] as? [[String: Any]])?.count ?? 0
}

/// Today's charging goal: the target state of charge and the time it should be reached by.
///
/// `SmartFlexVehicle.chargingPreferences` is deprecated in favour of `preferences`, which is also
/// the only one that carries the ready-by time. The schedule is per day of week; times are local.
func todaysChargeGoal(_ preferences: [String: Any]?, now: Date, tz: TimeZone) -> (target: Int?, readyBy: Int?) {
    guard let preferences else { return (nil, nil) }
    let schedules = (preferences["schedules"] as? [[String: Any]]) ?? []
    let names = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
    let today = names[(calendar(tz).component(.weekday, from: now) - 1) % 7]
    guard
        let schedule = schedules.first(where: { ($0["dayOfWeek"] as? String)?.uppercased() == today })
            ?? schedules.first
    else { return (nil, nil) }
    // Only a percentage is a state of charge. The same field can hold a kWh or a mileage goal,
    // and printing one of those with a % after it would be a plain lie.
    let isPercentage = (preferences["unit"] as? String)?.uppercased() == "PERCENTAGE"
    let value = toDouble(schedule["max"]) ?? toDouble(schedule["upperLimit"])
    return (isPercentage ? value.map { Int($0.rounded()) } : nil, minutes(schedule["time"] as? String ?? ""))
}

/// The slow-moving half of a snapshot: prices, schedule, balance and agreements. Fetched hourly,
/// or on demand, rather than on every refresh — it changes a few times a year, and fetching it
/// every five minutes was a third of the app's background requests.
struct TariffState {
    var accountNumber: String
    var mpan: String
    /// Both include VAT. Nil when the tariff states no fixed rates (Agile, for one): those come
    /// from `applicableRates`, which slides with the clock and so rides along on every refresh.
    var cheapRate: Double?
    var peakRate: Double?
    var standingCharge: Double?
    var windows: [(from: Int, to: Int)]
    var tz: TimeZone
    var balancePence: Int?
    var projectedBalancePence: Int?
    var tariffEnds: [TariffEnd]
    var propertyCount: Int
    var fetched: Date

    var ratesFromTariff: Bool { cheapRate != nil && peakRate != nil }
}

/// How long the tariff half of a snapshot is trusted before it is fetched again.
let tariffLifetime: TimeInterval = 60 * 60

/// Whether a cached tariff can stand in for a fresh one. Never across a change of meter or account,
/// and never when the refresh was asked for — "Refresh Now" should mean everything.
func tariffIsReusable(_ cached: TariffState?, account: String, mpan: String, now: Date, force: Bool) -> Bool {
    guard !force, let cached, cached.accountNumber == account, cached.mpan == mpan else { return false }
    return now.timeIntervalSince(cached.fetched) < tariffLifetime
}

/// Reads the tariff half out of the `account` node. Pure, so `--selftest` can cover it.
func parseTariffState(_ accountNode: [String: Any], account: String, mpan: String, now: Date) throws -> TariffState {
    let agreements = (accountNode["electricityAgreements"] as? [[String: Any]]) ?? []
    // The agreement for this meter, not merely the first import on the account.
    guard
        let agreement = agreements.first(where: {
            ($0["meterPoint"] as? [String: Any])?["mpan"] as? String == mpan
        })
    else { throw ApiError(message: "No active agreement for meter \(mpan)") }

    let scheme = agreement["timeOfUseScheme"] as? [String: Any]
    let tz = TimeZone(identifier: scheme?["timezone"] as? String ?? "") ?? TimeZone(identifier: "Europe/London")!
    var windows: [(from: Int, to: Int)] = []
    for slot in (scheme?["timeslots"] as? [[String: Any]]) ?? [] {
        let name = (slot["timeslot"] as? String ?? "").lowercased()
        guard ["off", "cheap", "night"].contains(where: name.contains),
            let from = minutes(slot["activeFrom"] as? String ?? ""),
            let to = minutes(slot["activeTo"] as? String ?? "")
        else { continue }
        windows.append((from, to))
    }
    if windows.isEmpty { windows = fallbackWindows }

    // The tariff's own rates include VAT and come named, so there is no guessing which is cheap.
    let tariff = agreement["tariff"] as? [String: Any] ?? [:]
    let tariffRates = ["unitRate", "dayRate", "nightRate", "offPeakRate", "evDevicePeakRate", "evDeviceOffPeakRate"]
        .compactMap { toDouble(tariff[$0]) }
        .filter { $0 > 0 }

    return TariffState(
        accountNumber: account, mpan: mpan, cheapRate: tariffRates.min(), peakRate: tariffRates.max(),
        standingCharge: toDouble(tariff["standingCharge"]), windows: windows, tz: tz,
        balancePence: (accountNode["balance"] as? NSNumber)?.intValue,
        projectedBalancePence: (accountNode["projectedBalance"] as? NSNumber)?.intValue,
        tariffEnds: parseTariffEnds(accountNode, now: now),
        propertyCount: propertyCount(accountNode), fetched: now)
}

/// The fast-moving half in one request: the devices, the charge plan for each device already known,
/// completed dispatches, and — only for a tariff with no fixed rates — the rates themselves.
///
/// `flexPlannedDispatches` is keyed by device, so the ids have to be known before it can be asked
/// for. They are taken from the previous refresh; a device that appears in the list but not in the
/// ids gets its plan from a follow-up request, once, and is known from then on.
func deviceQuery(deviceIds: [String], includeRates: Bool) -> String {
    let rateDefs = includeRates ? ",$m:String!,$s:DateTime!,$e:DateTime!,$n:Int!" : ""
    let rateField = includeRates
        ? "\n  applicableRates(accountNumber:$a,mpxn:$m,startAt:$s,endAt:$e,first:$n){edges{node{value}}}" : ""
    let flexDefs = deviceIds.indices.map { ",$d\($0):String!" }.joined()
    let flexFields = deviceIds.indices
        .map { "\n  f\($0): flexPlannedDispatches(deviceId:$d\($0)){start end type energyAddedKwh}" }
        .joined()
    return """
        query($a:String!\(rateDefs)\(flexDefs)){
          devices(accountNumber:$a){
            __typename id name
            ... on SmartFlexVehicle{
              make model vehicleBatterySize
              status{... on SmartFlexVehicleStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
              preferences{unit schedules{dayOfWeek time max upperLimit}}
            }
            ... on SmartFlexChargePoint{
              status{... on SmartFlexChargePointStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
            }
          }
          completedDispatches(accountNumber:$a){start end}\(rateField)\(flexFields)
        }
        """
}

/// The ids of the smart devices in a `devices` reply, in order.
func smartDeviceIds(_ data: [String: Any]) -> [String] {
    ((data["devices"] as? [[String: Any]]) ?? []).compactMap { device in
        let type = device["__typename"] as? String
        guard type == "SmartFlexVehicle" || type == "SmartFlexChargePoint" else { return nil }
        return device["id"] as? String
    }
}

/// Cars and dispatches out of a `deviceQuery` reply. `deviceIds` are the ones the query asked
/// plans for, which is what its `f0`, `f1`… aliases refer to.
func parseDeviceState(_ data: [String: Any], deviceIds: [String], now: Date, tz: TimeZone) -> (cars: [Car], dispatches: [Interval]) {
    var cars: [Car] = []
    for d in (data["devices"] as? [[String: Any]]) ?? [] {
        let type = d["__typename"] as? String
        guard type == "SmartFlexVehicle" || type == "SmartFlexChargePoint" else { continue }
        let status = d["status"] as? [String: Any]
        let soc = status?["stateOfCharge"] as? [String: Any]
        let power = status?["activePower"] as? [String: Any]
        let goal = todaysChargeGoal(d["preferences"] as? [String: Any], now: now, tz: tz)
        let label = [d["make"], d["model"]].compactMap { $0 as? String }.joined(separator: " ")
        cars.append(
            Car(
                name: label.isEmpty ? (d["name"] as? String ?? "Vehicle") : label,
                soc: toDouble(soc?["value"]),
                batteryKwh: toDouble(d["vehicleBatterySize"]),
                target: goal.target,
                readyBy: goal.readyBy,
                state: status?["currentState"] as? String,
                asOf: parseDate(soc?["timestamp"]),
                powerKw: toDouble(power?["value"]),
                powerAsOf: parseDate(power?["timestamp"]),
                suspended: status?["isSuspended"] as? Bool))
    }

    var dispatches: [Interval] = []
    for index in deviceIds.indices {
        for row in (data["f\(index)"] as? [[String: Any]]) ?? [] {
            guard let from = parseDate(row["start"]), let to = parseDate(row["end"]) else { continue }
            // Energy is stated negative for import; the sign says nothing the label doesn't.
            dispatches.append(
                Interval(
                    start: from, end: to, smart: true,
                    plannedKwh: toDouble(row["energyAddedKwh"]).map(abs),
                    chargeType: row["type"] as? String))
        }
    }
    // Completed slots carry no plan any more, and are kept only so a charge that has just run
    // still counts as a cheap window.
    for row in (data["completedDispatches"] as? [[String: Any]]) ?? [] {
        guard let from = parseDate(row["start"]), let to = parseDate(row["end"]) else { continue }
        dispatches.append(Interval(start: from, end: to, smart: true))
    }
    return (cars, dispatches)
}

/// One refresh. Normally a single request — devices, plan and completed dispatches — with the
/// tariff reused from the last hour; two when the tariff is due; one more the first time a device
/// is seen. It used to be six, every five minutes.
///
/// - Parameter force: fetch the tariff whatever its age, as "Refresh Now" and a key or meter change do.
func fetchSnapshot(apiKey: String, force: Bool = false) async throws -> Snapshot {
    let session = OctopusSession.shared
    let token = try await session.token(apiKey: apiKey)
    let choices = try await session.meters(apiKey: apiKey)
    guard let choice = MeterPreference.resolve(from: choices, fuel: .electricity) else {
        throw ApiError(message: "No electricity import meter found")
    }
    let account = choice.accountNumber
    let mpan = choice.supplyPoint
    let now = Date()

    var tariff: TariffState
    if let cached = await session.tariff,
        tariffIsReusable(cached, account: account, mpan: mpan, now: now, force: force)
    {
        tariff = cached
    } else {
        // Balance and agreement end dates hang off the same `account` node as the tariff, so they
        // ride along on this request rather than costing another one. Intelligent Octopus Go
        // arrives as a HalfHourlyTariff, whose unitRates list is of unknown shape, so only its
        // standing charge is taken; its prices come from applicableRates.
        let agr = try await gql(
            """
            query($a:String!){account(accountNumber:$a){
              balance
              projectedBalance
              electricityAgreements(active:true){
                validTo
                meterPoint{mpan direction}
                timeOfUseScheme{timezone timeslots{timeslot activeFrom activeTo}}
                tariff{
                  __typename
                  ... on TariffType{displayName}
                  ... on StandardTariff{unitRate standingCharge}
                  ... on PrepayTariff{unitRate standingCharge}
                  ... on DayNightTariff{dayRate nightRate standingCharge}
                  ... on ThreeRateTariff{dayRate nightRate offPeakRate standingCharge}
                  ... on FourRateEvTariff{
                    dayRate nightRate evDevicePeakRate evDeviceOffPeakRate standingCharge
                  }
                  ... on HalfHourlyTariff{standingCharge}
                }
              }
              properties{
                id
                address
                electricityMeterPoints{
                  agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}
                }
                gasMeterPoints{
                  agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}
                }
              }
            }}
            """, ["a": account], token: token)
        tariff = try parseTariffState(
            agr["account"] as? [String: Any] ?? [:], account: account, mpan: mpan, now: now)
        await session.setTariff(tariff)
    }

    // Everything that moves, in one request. A tariff with no fixed rates needs applicableRates,
    // which excludes VAT and only gives a set of values — and which errors without a page size, so
    // the size steps down if Octopus objects to it.
    let includeRates = !tariff.ratesFromTariff
    func request(_ ids: [String]) async throws -> [String: Any] {
        var variables: [String: Any] = ["a": account]
        for (index, id) in ids.enumerated() { variables["d\(index)"] = id }
        guard includeRates else {
            return try await gql(deviceQuery(deviceIds: ids, includeRates: false), variables, token: token)
        }
        variables["m"] = mpan
        variables["s"] = iso8601(now)
        variables["e"] = iso8601(now.addingTimeInterval(24 * 3600))
        var lastError = ApiError(message: "No rates returned")
        for size in [100, 50, 25, 10] {
            variables["n"] = size
            do {
                return try await gql(deviceQuery(deviceIds: ids, includeRates: true), variables, token: token)
            } catch let e as ApiError {
                lastError = e
                if !e.message.lowercased().contains("pagination") { throw e }
            }
        }
        throw lastError
    }

    var knownIds = await session.deviceIds(account: account)
    var data: [String: Any]?
    do {
        var reply = try await request(knownIds)
        let found = smartDeviceIds(reply)
        if found != knownIds {
            // A device the plan wasn't asked for — first launch, or a new charger. Ask again with
            // the full list, so this refresh is complete rather than the next one.
            knownIds = found
            await session.setDeviceIds(found, account: account)
            reply = try await request(found)
        }
        data = reply
    } catch {
        // A stale id makes its flexPlannedDispatches alias error, and with it the whole request.
        // Forget the ids, so the next attempt rediscovers them rather than failing the same way.
        await session.setDeviceIds([], account: account)
        // Without fixed rates this request was the only source of prices, so there is nothing to show.
        if includeRates { throw error }
    }

    let cheap: Double
    let peak: Double
    if let low = tariff.cheapRate, let high = tariff.peakRate {
        (cheap, peak) = (low, high)
    } else {
        let edges = ((data?["applicableRates"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        let values = edges.compactMap { toDouble(($0["node"] as? [String: Any])?["value"]) }
        guard let low = values.min(), let high = values.max() else {
            throw ApiError(message: "No rates returned")
        }
        // Grossed up by VAT so the two sources can never disagree on screen.
        (cheap, peak) = (low * vatMultiplier, high * vatMultiplier)
    }

    // Charge level is secondary; the rate display still works without it. But a failed device
    // request loses the charge plan too, and an empty plan is not a cancelled one — so say the
    // devices are unknown rather than letting the snapshot claim there are none.
    let devices = data.map { parseDeviceState($0, deviceIds: knownIds, now: now, tz: tariff.tz) }
    return Snapshot(
        cheapRate: cheap, peakRate: peak, standingCharge: tariff.standingCharge, windows: tariff.windows,
        dispatches: devices?.dispatches ?? [], cars: devices?.cars ?? [], devicesKnown: devices != nil,
        balancePence: tariff.balancePence, projectedBalancePence: tariff.projectedBalancePence,
        tariffEnds: tariff.tariffEnds, propertyCount: tariff.propertyCount,
        tz: tariff.tz, fetched: now)
}

private func iso8601(_ date: Date) -> String { isoParsers.whole.string(from: date) }
