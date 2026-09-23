// Octopus GraphQL API: obtain a token from the API key, then fetch tariff, schedule and cars.

import Foundation

struct ApiError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func toDouble(_ any: Any?) -> Double? {
    if let s = any as? String { return Double(s) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}

func parseDate(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
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
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ApiError(message: "Unexpected response")
    }
    if let errors = body["errors"] as? [[String: Any]], let first = errors.first {
        throw ApiError(message: first["message"] as? String ?? "GraphQL error")
    }
    return body["data"] as? [String: Any] ?? [:]
}

let fallbackWindows = [(from: 23 * 60 + 30, to: 5 * 60 + 30)]

/// Fixed agreements on the account that haven't ended, soonest first.
///
/// Takes the raw `account` node so it can be exercised without the network. Agreements with no
/// `validTo` are variable tariffs that never run out, and are not included. Two meters on the same
/// tariff ending the same day collapse into one entry — that is one thing to be told about.
/// Every active agreement on the account, one entry per meter point, never merged.
///
/// Includes variable tariffs, which have no `validTo` — Intelligent Octopus Go is one, and it is
/// the very tariff the menu bar's prices come from, so leaving it out made the menu silent about
/// it. Two houses on the same tariff stay two entries: the list is what the account holds.
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

func fetchSnapshot(apiKey: String) async throws -> Snapshot {
    let auth = try await gql(
        "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": apiKey])
    guard let token = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String else {
        throw ApiError(message: "Login failed")
    }

    let choices = try await discoverMeters(token: token)
    guard let choice = MeterPreference.resolve(from: choices, fuel: .electricity) else {
        throw ApiError(message: "No electricity import meter found")
    }
    let account = choice.accountNumber
    let mpan = choice.supplyPoint

    // The tariff's own rates include VAT and come named, so there is no guessing which is cheap.
    // applicableRates excludes VAT and only gives a set of values, so it is the fallback.
    // Balance and agreement end dates hang off the same `account` node as the tariff, so they
    // ride along on this request rather than costing another one.
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
            }
          }
          properties{
            id
            address
            electricityMeterPoints{
              agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}
            }
            gasMeterPoints{
              agreements{validFrom validTo tariff{... on TariffType{displayName}}}
            }
          }
        }}
        """, ["a": account], token: token)
    let accountNode = agr["account"] as? [String: Any] ?? [:]
    let agreements = (accountNode["electricityAgreements"] as? [[String: Any]]) ?? []
    // The agreement for this meter, not merely the first import on the account.
    guard
        let agreement = agreements.first(where: {
            ($0["meterPoint"] as? [String: Any])?["mpan"] as? String == mpan
        })
    else { throw ApiError(message: "No active agreement for meter \(mpan)") }

    let now = Date()
    let iso = ISO8601DateFormatter()

    // The schedule first: the device parsing below needs the property's timezone.
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

    // Devices before rates, because the planned-dispatch query is per device: their ids have to
    // be known before the rates request can ask for the charge plan in the same round trip.
    var cars: [Car] = []
    var deviceIds: [String] = []
    do {
        let dev = try await gql(
            """
            query($a:String!){devices(accountNumber:$a){
              __typename id name
              ... on SmartFlexVehicle{
                make model vehicleBatterySize
                status{... on SmartFlexVehicleStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
                preferences{unit schedules{dayOfWeek time max upperLimit}}
              }
              ... on SmartFlexChargePoint{
                status{... on SmartFlexChargePointStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
              }
            }}
            """, ["a": account], token: token)
        for d in (dev["devices"] as? [[String: Any]]) ?? [] {
            let type = d["__typename"] as? String
            guard type == "SmartFlexVehicle" || type == "SmartFlexChargePoint" else { continue }
            if let id = d["id"] as? String { deviceIds.append(id) }
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
    } catch {
        // Charge level is secondary; the rate display still works without it.
    }

    // `plannedDispatches` is deprecated — and gave only start and end. `flexPlannedDispatches`
    // also carries the planned energy and whether a slot is a smart charge or a boost, but it is
    // per device, so one alias per device keeps it to a single request however many there are.
    var flexDefs = ""
    var flexFields = ""
    var flexVariables: [String: Any] = [:]
    for (index, id) in deviceIds.enumerated() {
        flexDefs += ",$d\(index):String!"
        flexFields += "\n  f\(index): flexPlannedDispatches(deviceId:$d\(index)){start end type energyAddedKwh}"
        flexVariables["d\(index)"] = id
    }

    let ratesQuery = """
        query($a:String!,$m:String!,$s:DateTime!,$e:DateTime!,$n:Int!\(flexDefs)){
          applicableRates(accountNumber:$a,mpxn:$m,startAt:$s,endAt:$e,first:$n){edges{node{value}}}
          completedDispatches(accountNumber:$a){start end}\(flexFields)
        }
        """
    var ratesData: [String: Any]?
    var lastError = ""
    for size in [100, 50, 25, 10] {
        do {
            var variables: [String: Any] = [
                "a": account, "m": mpan, "n": size,
                "s": iso.string(from: now), "e": iso.string(from: now.addingTimeInterval(24 * 3600)),
            ]
            variables.merge(flexVariables) { current, _ in current }
            ratesData = try await gql(ratesQuery, variables, token: token)
            break
        } catch let e as ApiError {
            lastError = e.message
            if !e.message.lowercased().contains("pagination") { throw e }
        }
    }
    guard let rd = ratesData else { throw ApiError(message: lastError) }

    // Prefer the tariff's VAT-inclusive rates; fall back to applicableRates, grossing up by the
    // VAT the tariff implies so the two sources can never disagree on screen.
    let tariff = agreement["tariff"] as? [String: Any] ?? [:]
    let tariffRates = ["unitRate", "dayRate", "nightRate", "offPeakRate", "evDevicePeakRate", "evDeviceOffPeakRate"]
        .compactMap { toDouble(tariff[$0]) }
        .filter { $0 > 0 }

    let cheap: Double
    let peak: Double
    if let low = tariffRates.min(), let high = tariffRates.max() {
        (cheap, peak) = (low, high)
    } else {
        let edges = ((rd["applicableRates"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
        let values = edges.compactMap { toDouble(($0["node"] as? [String: Any])?["value"]) }
        guard let low = values.min(), let high = values.max() else {
            throw ApiError(message: "No rates returned")
        }
        (cheap, peak) = (low * vatMultiplier, high * vatMultiplier)
    }
    let standingCharge = toDouble(tariff["standingCharge"])

    var dispatches: [Interval] = []
    for index in deviceIds.indices {
        for row in (rd["f\(index)"] as? [[String: Any]]) ?? [] {
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
    for row in (rd["completedDispatches"] as? [[String: Any]]) ?? [] {
        guard let from = parseDate(row["start"]), let to = parseDate(row["end"]) else { continue }
        dispatches.append(Interval(start: from, end: to, smart: true))
    }

    return Snapshot(
        cheapRate: cheap, peakRate: peak, standingCharge: standingCharge, windows: windows,
        dispatches: dispatches, cars: cars,
        balancePence: (accountNode["balance"] as? NSNumber)?.intValue,
        projectedBalancePence: (accountNode["projectedBalance"] as? NSNumber)?.intValue,
        tariffEnds: parseTariffEnds(accountNode, now: now),
        propertyCount: propertyCount(accountNode),
        tz: tz, fetched: now)
}
