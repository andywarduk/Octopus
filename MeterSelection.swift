// Which account, property and electricity meter the app reports on.
//
// Picking the first of each list independently is wrong on a multi-property account: the property
// and the MPAN can belong to different addresses, and the measurements query then asks one
// property for another's meter. These are discovered as matched pairs instead.

import Foundation

struct MeterChoice: Equatable {
    var accountNumber: String
    var propertyId: String
    var address: String
    var mpan: String

    /// Stable across launches, so a saved preference survives reordering.
    var id: String { "\(accountNumber)|\(propertyId)|\(mpan)" }

    var label: String {
        let place = address.split(separator: "\n").first.map(String.init) ?? address
        return place.isEmpty ? "MPAN \(mpan)" : "\(place) · \(mpan)"
    }
}

enum MeterPreference {
    static let key = "selectedMeter"

    static var savedId: String? { UserDefaults.standard.string(forKey: key) }

    static func save(_ choice: MeterChoice?) {
        guard let choice else { return UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(choice.id, forKey: key)
    }

    /// The saved choice if it still exists, else the first. Never silently picks a different
    /// meter than the one that was saved.
    static func resolve(from choices: [MeterChoice]) -> MeterChoice? {
        if let savedId, let match = choices.first(where: { $0.id == savedId }) { return match }
        return choices.first
    }
}

/// Every import meter on the account, paired with the property it actually sits at.
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
              properties{id address electricityMeterPoints{mpan direction}}
              electricityAgreements(active:true){meterPoint{mpan}}
            }}
            """, ["a": number], token: token)
        let acc = data["account"] as? [String: Any] ?? [:]
        // Only meters with a live agreement: an old one at a previous address has no rates.
        let active = Set(
            ((acc["electricityAgreements"] as? [[String: Any]]) ?? []).compactMap {
                ($0["meterPoint"] as? [String: Any])?["mpan"] as? String
            })
        for property in (acc["properties"] as? [[String: Any]]) ?? [] {
            guard let propertyId = property["id"] as? String else { continue }
            for point in (property["electricityMeterPoints"] as? [[String: Any]]) ?? [] {
                guard
                    let mpan = point["mpan"] as? String,
                    (point["direction"] as? String)?.uppercased() != "EXPORT",
                    active.contains(mpan)
                else { continue }
                choices.append(
                    MeterChoice(
                        accountNumber: number, propertyId: propertyId,
                        address: property["address"] as? String ?? "", mpan: mpan))
            }
        }
    }
    guard !choices.isEmpty else { throw ApiError(message: "No electricity import meter found") }
    return choices
}
