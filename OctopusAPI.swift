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

func fetchSnapshot(apiKey: String) async throws -> Snapshot {
    let auth = try await gql(
        "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": apiKey])
    guard let token = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String else {
        throw ApiError(message: "Login failed")
    }

    let choices = try await discoverMeters(token: token)
    guard let choice = MeterPreference.resolve(from: choices) else {
        throw ApiError(message: "No electricity import meter found")
    }
    let account = choice.accountNumber
    let mpan = choice.mpan

    let agr = try await gql(
        """
        query($a:String!){account(accountNumber:$a){electricityAgreements(active:true){
          meterPoint{mpan direction}
          timeOfUseScheme{timezone timeslots{timeslot activeFrom activeTo}}
        }}}
        """, ["a": account], token: token)
    let agreements = ((agr["account"] as? [String: Any])?["electricityAgreements"] as? [[String: Any]]) ?? []
    // The agreement for this meter, not merely the first import on the account.
    guard
        let agreement = agreements.first(where: {
            ($0["meterPoint"] as? [String: Any])?["mpan"] as? String == mpan
        })
    else { throw ApiError(message: "No active agreement for meter \(mpan)") }

    let now = Date()
    let iso = ISO8601DateFormatter()
    let ratesQuery = """
        query($a:String!,$m:String!,$s:DateTime!,$e:DateTime!,$n:Int!){
          applicableRates(accountNumber:$a,mpxn:$m,startAt:$s,endAt:$e,first:$n){edges{node{value}}}
          plannedDispatches(accountNumber:$a){start end}
          completedDispatches(accountNumber:$a){start end}
        }
        """
    var ratesData: [String: Any]?
    var lastError = ""
    for size in [100, 50, 25, 10] {
        do {
            ratesData = try await gql(
                ratesQuery,
                [
                    "a": account, "m": mpan, "n": size,
                    "s": iso.string(from: now), "e": iso.string(from: now.addingTimeInterval(24 * 3600)),
                ], token: token)
            break
        } catch let e as ApiError {
            lastError = e.message
            if !e.message.lowercased().contains("pagination") { throw e }
        }
    }
    guard let rd = ratesData else { throw ApiError(message: lastError) }

    let edges = ((rd["applicableRates"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
    let values = edges.compactMap { toDouble(($0["node"] as? [String: Any])?["value"]) }
    guard let cheap = values.min(), let peak = values.max() else { throw ApiError(message: "No rates returned") }

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

    let dispatchRows = ((rd["plannedDispatches"] as? [[String: Any]]) ?? []) + ((rd["completedDispatches"] as? [[String: Any]]) ?? [])
    let dispatches = dispatchRows.compactMap { row -> Interval? in
        guard let s = parseDate(row["start"]), let e = parseDate(row["end"]) else { return nil }
        return Interval(start: s, end: e, smart: true)
    }

    var cars: [Car] = []
    do {
        let dev = try await gql(
            """
            query($a:String!){devices(accountNumber:$a){
              __typename id name
              ... on SmartFlexVehicle{
                make model
                status{... on SmartFlexVehicleStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
                chargingPreferences{weekdayTargetSoc weekendTargetSoc}
              }
              ... on SmartFlexChargePoint{
                status{... on SmartFlexChargePointStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
              }
            }}
            """, ["a": account], token: token)
        let weekend = calendar(tz).isDateInWeekend(now)
        for d in (dev["devices"] as? [[String: Any]]) ?? [] {
            let type = d["__typename"] as? String
            guard type == "SmartFlexVehicle" || type == "SmartFlexChargePoint" else { continue }
            let status = d["status"] as? [String: Any]
            let soc = status?["stateOfCharge"] as? [String: Any]
            let power = status?["activePower"] as? [String: Any]
            let prefs = d["chargingPreferences"] as? [String: Any]
            let label = [d["make"], d["model"]].compactMap { $0 as? String }.joined(separator: " ")
            cars.append(
                Car(
                    name: label.isEmpty ? (d["name"] as? String ?? "Vehicle") : label,
                    soc: toDouble(soc?["value"]),
                    target: (prefs?[weekend ? "weekendTargetSoc" : "weekdayTargetSoc"] as? NSNumber)?.intValue,
                    state: status?["currentState"] as? String,
                    asOf: parseDate(soc?["timestamp"]),
                    powerKw: toDouble(power?["value"]),
                    powerAsOf: parseDate(power?["timestamp"]),
                    suspended: status?["isSuspended"] as? Bool))
        }
    } catch {
        // Charge level is secondary; the rate display still works without it.
    }

    return Snapshot(cheapRate: cheap, peakRate: peak, windows: windows, dispatches: dispatches, cars: cars, tz: tz, fetched: now)
}
