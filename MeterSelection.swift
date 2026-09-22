// Which account, property and meter the app reports on.
//
// Picking the first of each list independently is wrong on a multi-property account: the property
// and the supply point can belong to different addresses, and the measurements query then asks one
// property for another's meter. These are discovered as matched pairs instead.

import Foundation

enum Fuel: String, CaseIterable {
    case electricity, gas

    var title: String { self == .electricity ? "Electricity" : "Gas" }
    var windowTitle: String { "\(title) Use" }
    /// Electricity is metered in kWh; gas may report cubic metres, so its unit comes from the data.
    var defaultEnergyLabel: String { "kWh" }
}

struct MeterChoice: Equatable {
    var fuel: Fuel
    var accountNumber: String
    var propertyId: String
    var address: String
    /// Carried so the carbon intensity window has a region to ask about without another request.
    var postcode: String = ""
    /// MPAN for electricity, MPRN for gas.
    var supplyPoint: String

    /// Stable across launches, so a saved preference survives reordering.
    var id: String { "\(fuel.rawValue)|\(accountNumber)|\(propertyId)|\(supplyPoint)" }

    var label: String {
        let place = address.split(separator: ",").first.map(String.init) ?? address
        let trimmed = place.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? supplyPoint : "\(trimmed) · \(supplyPoint)"
    }
}

enum MeterPreference {
    static func key(_ fuel: Fuel) -> String { "selectedMeter.\(fuel.rawValue)" }

    static func savedId(_ fuel: Fuel) -> String? {
        UserDefaults.standard.string(forKey: key(fuel))
    }

    static func save(_ choice: MeterChoice) {
        UserDefaults.standard.set(choice.id, forKey: key(choice.fuel))
    }

    /// The saved choice if it still exists, else the first for that fuel. Never silently picks a
    /// different meter than the one that was saved.
    static func resolve(from choices: [MeterChoice], fuel: Fuel) -> MeterChoice? {
        let forFuel = choices.filter { $0.fuel == fuel }
        if let saved = savedId(fuel), let match = forFuel.first(where: { $0.id == saved }) { return match }
        return forFuel.first
    }
}

/// Every meter on the account, paired with the property it actually sits at.
func discoverMeters(token: String) async throws -> [MeterChoice] {
    let who = try await gql("{viewer{accounts{number}}}", token: token)
    guard let accounts = (who["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]],
        !accounts.isEmpty
    else { throw ApiError(message: "No account found") }

    var choices: [MeterChoice] = []
    for account in accounts {
        guard let number = account["number"] as? String else { continue }
        let data = try await gql(
            """
            query($a:String!){account(accountNumber:$a){
              properties{
                id
                address
                postcode
                electricityMeterPoints{mpan direction}
                gasMeterPoints{mprn}
              }
              electricityAgreements(active:true){meterPoint{mpan}}
              gasAgreements(active:true){meterPoint{mprn}}
            }}
            """, ["a": number], token: token)
        let acc = data["account"] as? [String: Any] ?? [:]
        // Only meters with a live agreement: an old one at a previous address has no rates.
        func liveSupplyPoints(_ field: String, _ key: String) -> Set<String> {
            Set(
                ((acc[field] as? [[String: Any]]) ?? []).compactMap {
                    ($0["meterPoint"] as? [String: Any])?[key] as? String
                })
        }
        let liveElectricity = liveSupplyPoints("electricityAgreements", "mpan")
        let liveGas = liveSupplyPoints("gasAgreements", "mprn")

        for property in (acc["properties"] as? [[String: Any]]) ?? [] {
            guard let propertyId = property["id"] as? String else { continue }
            let address = property["address"] as? String ?? ""
            let postcode = property["postcode"] as? String ?? ""
            for point in (property["electricityMeterPoints"] as? [[String: Any]]) ?? [] {
                guard
                    let mpan = point["mpan"] as? String,
                    (point["direction"] as? String)?.uppercased() != "EXPORT",
                    liveElectricity.contains(mpan)
                else { continue }
                choices.append(
                    MeterChoice(
                        fuel: .electricity, accountNumber: number, propertyId: propertyId,
                        address: address, postcode: postcode, supplyPoint: mpan))
            }
            for point in (property["gasMeterPoints"] as? [[String: Any]]) ?? [] {
                guard let mprn = point["mprn"] as? String, liveGas.contains(mprn) else { continue }
                choices.append(
                    MeterChoice(
                        fuel: .gas, accountNumber: number, propertyId: propertyId,
                        address: address, postcode: postcode, supplyPoint: mprn))
            }
        }
    }
    guard !choices.isEmpty else { throw ApiError(message: "No meter with an active agreement found") }
    return choices
}
