// The values the rest of the app works from: a Snapshot of tariff, schedule and car state.

import Foundation

struct Interval {
    var start: Date
    var end: Date
    var smart: Bool
}

struct Car {
    var name: String
    var soc: Double?
    var target: Int?
    /// When the target should be reached, in minutes after local midnight. Octopus states this in
    /// the property's own timezone, so 07:00 here is 07:00 on the wall clock whatever the season.
    var readyBy: Int?
    var state: String?
    var asOf: Date?
    var powerKw: Double?
    var powerAsOf: Date?
    var suspended: Bool?
}

/// A fixed-term agreement that runs out. Only agreements with an end date become one of these:
/// a variable tariff has `validTo: null` and never expires.
struct TariffEnd: Equatable {
    var fuel: Fuel
    var name: String
    var ends: Date

    /// Identifies the agreement across launches, so an alert isn't repeated. Two meters on the
    /// same tariff ending on the same day are one thing to tell you about, not two.
    var key: String { "\(fuel.rawValue)|\(name)|\(Int(ends.timeIntervalSince1970))" }
}

struct Snapshot {
    /// Both include VAT, matching the usage chart and your bill.
    var cheapRate: Double
    var peakRate: Double
    /// Daily standing charge in pence including VAT, when the tariff states one.
    var standingCharge: Double?
    var windows: [(from: Int, to: Int)]  // minutes after local midnight
    var dispatches: [Interval]
    var cars: [Car]
    /// Account balance and the balance Octopus expects in a year, both in pence. Positive is
    /// credit. Nil when the account didn't report them.
    var balancePence: Int?
    var projectedBalancePence: Int?
    /// Every fixed agreement on the account that has not ended yet, soonest first.
    var tariffEnds: [TariffEnd] = []
    var tz: TimeZone
    var fetched: Date

    /// A single-rate tariff has no cheap window, whatever the schedule says.
    var hasCheapRate: Bool { peakRate - cheapRate >= 0.01 }
}

enum Line {
    case header(String)
    case text(String)
    case separator
}
