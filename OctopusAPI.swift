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

/// Whether a failure is this Mac's network rather than Octopus's answer: asleep, just woken, or
/// between networks. Such failures say nothing about the key or the token, so they neither drop the
/// session nor count toward stopping automatic refreshes.
func isOffline(_ error: Error) -> Bool {
    guard let code = (error as? URLError)?.code else { return false }
    let offline: [URLError.Code] = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
        .timedOut, .dataNotAllowed, .internationalRoamingOff,
    ]
    return offline.contains(code)
}

/// Drops the cached token and meters unless the error is known not to concern them.
func invalidateSession(after error: Error) async {
    if (error as? ApiError)?.invalidatesSession == false || isOffline(error) { return }
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

/// The errors that should fail a request: all but those whose path runs through one of `fields`.
/// GraphQL answers everything else alongside them, and something optional — live power, say —
/// failing must not take the prices or the charge plan down with it.
func untoleratedErrors(_ errors: [[String: Any]], tolerating fields: Set<String>) -> [[String: Any]] {
    errors.filter { error in
        let path = (error["path"] as? [Any]) ?? []
        return !path.contains { ($0 as? String).map(fields.contains) ?? false }
    }
}

/// - Parameter tolerating: fields whose errors are dropped, leaving them null in the reply.
func gql(
    _ query: String, _ variables: [String: Any] = [:], token: String? = nil, tolerating: Set<String> = []
) async throws -> [String: Any] {
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
    if let errors = body?["errors"] as? [[String: Any]],
        let first = untoleratedErrors(errors, tolerating: tolerating).first
    {
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

let fallbackWindows: [TimeWindow] = [(from: 23 * 60 + 30, to: 5 * 60 + 30)]

/// The off-peak windows a `timeOfUseScheme` states, in minutes after local midnight. Empty when it
/// states none: Agile, for one, has no timetable.
func offPeakWindows(_ scheme: [String: Any]?) -> [TimeWindow] {
    var windows: [TimeWindow] = []
    for slot in (scheme?["timeslots"] as? [[String: Any]]) ?? [] {
        let name = (slot["timeslot"] as? String ?? "").lowercased()
        guard ["off", "cheap", "night"].contains(where: name.contains),
            let from = minutes(slot["activeFrom"] as? String ?? ""),
            let to = minutes(slot["activeTo"] as? String ?? "")
        else { continue }
        windows.append((from, to))
    }
    return windows
}

/// Whether `instant` falls in one of `windows`, which may run across midnight.
func inWindows(_ instant: Date, _ windows: [TimeWindow], cal: Calendar) -> Bool {
    let minute = cal.component(.hour, from: instant) * 60 + cal.component(.minute, from: instant)
    return windows.contains { w in
        w.from < w.to ? (w.from <= minute && minute < w.to) : (minute >= w.from || minute < w.to)
    }
}

/// Every active agreement on the account, one entry per meter point, never merged.
///
/// Includes variable tariffs, which have no `validTo` — Intelligent Octopus Go is one, and it is
/// the very tariff the menu bar's prices come from, so leaving it out made the menu silent about
/// it. Two houses on the same tariff stay two entries: the list is what the account holds. Takes
/// the raw `account` node so it can be exercised without the network.
func parseTariffEnds(_ account: [String: Any], accountNumber: String = "", now: Date) -> [TariffEnd] {
    var found: [TariffEnd] = []
    for property in (account["properties"] as? [[String: Any]]) ?? [] {
        let address = property["address"] as? String ?? ""
        let place = firstLine(of: address)
        for (field, fuel) in [("electricityMeterPoints", Fuel.electricity), ("gasMeterPoints", .gas)] {
            for point in (property[field] as? [[String: Any]]) ?? [] {
                // The meter behind the agreement, so the menu can open its usage from the tariff
                // it sits under — without waiting on meter discovery. Export has no usage to show.
                let supplyPoint = (point["mpan"] ?? point["mprn"]) as? String
                let isExport = (point["direction"] as? String)?.uppercased() == "EXPORT"
                let meter = supplyPoint.flatMap { supply -> MeterChoice? in
                    guard !isExport, let propertyId = property["id"] as? String else { return nil }
                    return MeterChoice(
                        fuel: fuel, accountNumber: accountNumber, propertyId: propertyId,
                        address: address, postcode: property["postcode"] as? String ?? "",
                        supplyPoint: supply, homeMiniDevice: homeMiniDevice(for: fuel, in: property))
                }
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
                            property: place, meter: meter))
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

/// The objects in a JSON list, skipping nulls: a list whose items are nullable can hold some, and
/// casting it straight to `[[String: Any]]` would then drop the whole list.
private func objects(_ any: Any?) -> [[String: Any]] {
    ((any as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
}

/// The devices on a property's home area networks that share a network with a Home Mini (a CAD),
/// as (type, device id). Telemetry answers only for these: without the Mini it returns no rows and
/// no error. The Mini reports `NOT_APPLICABLE` while working perfectly, so nothing is filtered on
/// `COMMISSIONED`; only devices taken off the network drop out.
func homeMiniDevices(_ property: [String: Any]) -> [(type: String, deviceId: String)] {
    let gone: Set<String> = ["DECOMMISSIONED", "WITHDRAWN"]
    var found: [(type: String, deviceId: String)] = []
    for network in objects(property["smartDeviceNetworks"]) {
        let devices = objects(network["smartDevices"]).filter {
            !gone.contains(($0["status"] as? String ?? "").uppercased())
        }
        func type(_ device: [String: Any]) -> String { (device["type"] as? String ?? "").uppercased() }
        guard devices.contains(where: { ["CAD", "IHD_OR_CAD"].contains(type($0)) }) else { continue }
        for device in devices {
            guard let id = device["deviceId"] as? String else { continue }
            found.append((type(device), id))
        }
    }
    return found
}

/// The meters that can report live power: each electricity meter (ESME) on a network with a Mini.
func parseLiveMeters(_ account: [String: Any]) -> [LiveMeter] {
    objects(account["properties"]).flatMap { property in
        let place = firstLine(of: property["address"] as? String ?? "")
        return homeMiniDevices(property).filter { $0.type == "ESME" }.map {
            LiveMeter(deviceId: $0.deviceId, property: place)
        }
    }
}

/// The device id of the one meter of `fuel` on a property's network with a Mini, so its usage can
/// be filled in from telemetry before Octopus publishes it. Nil unless it is unambiguous: the
/// network lists devices, not supply points, so with two gas meters at one address there is no
/// telling which is which.
func homeMiniDevice(for fuel: Fuel, in property: [String: Any]) -> String? {
    let field = fuel == .electricity ? "electricityMeterPoints" : "gasMeterPoints"
    let points = objects(property[field]).filter { ($0["direction"] as? String)?.uppercased() != "EXPORT" }
    let meters = homeMiniDevices(property).filter { $0.type == (fuel == .electricity ? "ESME" : "GSME") }
    guard points.count == 1, meters.count == 1 else { return nil }
    return meters[0].deviceId
}

/// How far back the live power query looks. The Mini reports every ten seconds, so five minutes
/// without a row means it has stopped, not that it is between readings.
let liveLookback: TimeInterval = 5 * 60

/// The newest reading in a `smartMeterTelemetry` reply. Rows arrive oldest first, but the newest is
/// looked for rather than assumed last. Figures are strings, sometimes in exponent form.
func latestTelemetry(_ rows: Any?) -> (watts: Double, at: Date)? {
    let readings = ((rows as? [Any]) ?? []).compactMap { row -> (watts: Double, at: Date)? in
        guard let row = row as? [String: Any], let at = parseDate(row["readAt"]),
            let watts = toDouble(row["demand"])
        else { return nil }
        return (watts, at)
    }
    return readings.max { $0.at < $1.at }
}

/// Live power out of a `deviceQuery` reply, one per meter in `meters`, which is what its `t0`,
/// `t1`… aliases refer to. A nil reply — the request failed — gives every meter no reading.
func parseLivePower(_ data: [String: Any]?, meters: [LiveMeter]) -> [LivePower] {
    meters.indices.map { index in
        let latest = latestTelemetry(data?["t\(index)"])
        return LivePower(meter: meters[index], watts: latest?.watts, at: latest?.at)
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

/// The VAT a tariff charges, read off its standing charge with and without tax — the API states no
/// rate, and it changes (0% on GB electricity from October 2026 to March 2027). Only used to gross
/// up the rare tariff that has no stated rates, since applicableRates quotes prices before tax
/// while everything else on screen includes it. Rounded to the nearest half percent — fine enough
/// for a rate like 17.5%, coarse enough that rounding in either figure can't leak in.
func vatMultiplier(standingCharge: Double?, preVat: Double?) -> Double? {
    guard let withVat = standingCharge, let preVat, preVat > 0 else { return nil }
    return (withVat / preVat * 200).rounded() / 200
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
    /// From the standing charge's with- and without-VAT figures; grosses up applicableRates.
    var vatMultiplier: Double?
    var windows: [TimeWindow]
    var tz: TimeZone
    var balancePence: Int?
    var projectedBalancePence: Int?
    var tariffEnds: [TariffEnd]
    var propertyCount: Int
    /// Meters with a Home Mini. Kept with the tariff because a Mini is paired about as often as a
    /// tariff changes, and its readings ride on the device request.
    var liveMeters: [LiveMeter] = []
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
    let tz = TimeZone(identifier: scheme?["timezone"] as? String ?? "") ?? londonTimeZone
    let stated = offPeakWindows(scheme)
    let windows = stated.isEmpty ? fallbackWindows : stated

    // The tariff's own rates include VAT and come named, so there is no guessing which is cheap.
    let tariff = agreement["tariff"] as? [String: Any] ?? [:]
    let tariffRates = ["unitRate", "dayRate", "nightRate", "offPeakRate", "evDevicePeakRate", "evDeviceOffPeakRate"]
        .compactMap { toDouble(tariff[$0]) }
        .filter { $0 > 0 }
    let standingCharge = toDouble(tariff["standingCharge"])

    return TariffState(
        accountNumber: account, mpan: mpan, cheapRate: tariffRates.min(), peakRate: tariffRates.max(),
        standingCharge: standingCharge,
        vatMultiplier: vatMultiplier(standingCharge: standingCharge, preVat: toDouble(tariff["preVatStandingCharge"])),
        windows: windows, tz: tz,
        balancePence: (accountNode["balance"] as? NSNumber)?.intValue,
        projectedBalancePence: (accountNode["projectedBalance"] as? NSNumber)?.intValue,
        tariffEnds: parseTariffEnds(accountNode, accountNumber: account, now: now),
        propertyCount: propertyCount(accountNode), liveMeters: parseLiveMeters(accountNode), fetched: now)
}

/// The fast-moving half in one request: the devices, the charge plan for each device already known,
/// completed dispatches, and — only for a tariff with no fixed rates — the rates themselves.
///
/// `flexPlannedDispatches` is keyed by device, so the ids have to be known before it can be asked
/// for. They are taken from the previous refresh; a device that appears in the list but not in the
/// ids gets its plan from a follow-up request, once, and is known from then on.
///
/// Live power rides here too, one `t0`, `t1`… alias per meter with a Home Mini, so it costs no
/// request of its own. The caller tolerates errors on those aliases.
func deviceQuery(deviceIds: [String], includeRates: Bool, liveMeters: Int = 0) -> String {
    let rateDefs = includeRates ? ",$m:String!,$s:DateTime!,$e:DateTime!,$n:Int!" : ""
    let rateField = includeRates
        ? "\n  applicableRates(accountNumber:$a,mpxn:$m,startAt:$s,endAt:$e,first:$n){edges{node{value}}}" : ""
    let flexDefs = deviceIds.indices.map { ",$d\($0):String!" }.joined()
    let flexFields = deviceIds.indices
        .map { "\n  f\($0): flexPlannedDispatches(deviceId:$d\($0)){start end type energyAddedKwh}" }
        .joined()
    let liveDefs = liveMeters > 0
        ? ",$ls:DateTime!,$le:DateTime!" + (0..<liveMeters).map { ",$t\($0):String!" }.joined() : ""
    let liveFields = (0..<liveMeters)
        .map { "\n  t\($0): smartMeterTelemetry(deviceId:$t\($0),start:$ls,end:$le,grouping:TEN_SECONDS){readAt demand}" }
        .joined()
    return """
        query($a:String!\(rateDefs)\(flexDefs)\(liveDefs)){
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
          completedDispatches(accountNumber:$a){start end}\(rateField)\(flexFields)\(liveFields)
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
        // standing charge is taken; its prices come from applicableRates, and the VAT to add to
        // them from the standing charge's pre-VAT twin. Each property's home area network says
        // whether it has a Home Mini; an error there only costs live power, so it is tolerated.
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
                  ... on HalfHourlyTariff{standingCharge preVatStandingCharge}
                }
              }
              properties{
                id
                address
                postcode
                electricityMeterPoints{
                  mpan direction
                  agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}
                }
                gasMeterPoints{
                  mprn
                  agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}
                }
                smartDeviceNetworks{smartDevices{deviceId type status}}
              }
            }}
            """, ["a": account], token: token, tolerating: ["smartDeviceNetworks"])
        tariff = try parseTariffState(
            agr["account"] as? [String: Any] ?? [:], account: account, mpan: mpan, now: now)
        await session.setTariff(tariff)
    }

    // Everything that moves, in one request. A tariff with no fixed rates needs applicableRates,
    // which excludes VAT and only gives a set of values — and which errors without a page size, so
    // the size steps down if Octopus objects to it.
    let includeRates = !tariff.ratesFromTariff
    let live = tariff.liveMeters
    let liveAliases = Set(live.indices.map { "t\($0)" })
    func request(_ ids: [String]) async throws -> [String: Any] {
        var variables: [String: Any] = ["a": account]
        for (index, id) in ids.enumerated() { variables["d\(index)"] = id }
        for (index, meter) in live.enumerated() { variables["t\(index)"] = meter.deviceId }
        if !live.isEmpty {
            variables["ls"] = iso8601(now.addingTimeInterval(-liveLookback))
            // A minute's grace, so a Mac clock running behind Octopus's can't cut off the newest row.
            variables["le"] = iso8601(now.addingTimeInterval(60))
        }
        func query(_ rates: Bool) -> String {
            deviceQuery(deviceIds: ids, includeRates: rates, liveMeters: live.count)
        }
        guard includeRates else {
            return try await gql(query(false), variables, token: token, tolerating: liveAliases)
        }
        variables["m"] = mpan
        variables["s"] = iso8601(now)
        variables["e"] = iso8601(now.addingTimeInterval(24 * 3600))
        var lastError = ApiError(message: "No rates returned")
        for size in [100, 50, 25, 10] {
            variables["n"] = size
            do {
                return try await gql(query(true), variables, token: token, tolerating: liveAliases)
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
        guard let vat = tariff.vatMultiplier else {
            throw ApiError(message: "Tariff states no pre-VAT standing charge to work out VAT from")
        }
        (cheap, peak) = (low * vat, high * vat)
    }

    // Charge level is secondary; the rate display still works without it. But a failed device
    // request loses the charge plan too, and an empty plan is not a cancelled one — so say the
    // devices are unknown rather than letting the snapshot claim there are none.
    let devices = data.map { parseDeviceState($0, deviceIds: knownIds, now: now, tz: tariff.tz) }
    return Snapshot(
        cheapRate: cheap, peakRate: peak, standingCharge: tariff.standingCharge, windows: tariff.windows,
        dispatches: devices?.dispatches ?? [], cars: devices?.cars ?? [], devicesKnown: devices != nil,
        livePower: parseLivePower(data, meters: live),
        balancePence: tariff.balancePence, projectedBalancePence: tariff.projectedBalancePence,
        tariffEnds: tariff.tariffEnds, propertyCount: tariff.propertyCount,
        tz: tariff.tz, fetched: now)
}

func iso8601(_ date: Date) -> String { isoParsers.whole.string(from: date) }
