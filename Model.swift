// The values the rest of the app works from: a Snapshot of tariff, schedule and car state.

import Foundation

struct Interval {
    var start: Date
    var end: Date
    var smart: Bool
    /// Energy the planner intends for a smart-charge slot, in kWh, positive.
    ///
    /// **Modelled, not measured.** Octopus states it at a flat assumed rate — on the development
    /// account 18.277 kWh over seven half hours, exactly 7 × 2.611, the same constant as the
    /// `EV_DEVICE_OFF_PEAK` billing allocation. It is the plan's own arithmetic, so say "about"
    /// and never present it as what the car drew.
    var plannedKwh: Double?
    /// `SMART`, `BOOST` or `TEST` — a boost is one you asked for, a smart charge one Octopus
    /// planned. Nil for a scheduled tariff window, which is not a dispatch at all.
    var chargeType: String?
}

struct Car {
    var name: String
    var soc: Double?
    /// Usable battery capacity in kWh, as the vehicle reports it. The charge held is this times
    /// the state of charge — derived, not a figure the API gives, so it is shown as "about".
    var batteryKwh: Double?
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

/// One active agreement, exactly as the account holds it — one per meter point, never merged.
/// Two houses on the same tariff are two agreements, and the menu says so.
struct TariffEnd: Equatable {
    var fuel: Fuel
    var name: String
    /// Nil for a variable tariff, which never runs out.
    var ends: Date?
    /// Short address of the property it covers.
    var property: String = ""

    /// What an alert is about. Deliberately excludes the property: the same tariff ending the
    /// same day at two addresses is one thing to be told about, even though the list shows both.
    var alertKey: String {
        "\(fuel.rawValue)|\(name)|\(ends.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }
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
    /// False when the device query failed. Then `cars` is empty and `dispatches` holds only
    /// completed slots — which is "don't know", not "no car and nothing planned", and must not be
    /// compared against a plan that was known.
    var devicesKnown = true
    /// Account balance and the balance Octopus expects in a year, both in pence. Positive is
    /// credit. Nil when the account didn't report them.
    var balancePence: Int?
    var projectedBalancePence: Int?
    /// Every active agreement on the account, one per meter point, in listing order.
    var tariffEnds: [TariffEnd] = []
    /// Addresses on the account. One means a tariff never needs naming a property.
    var propertyCount: Int = 1
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
