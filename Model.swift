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
    var state: String?
    var asOf: Date?
    var powerKw: Double?
    var powerAsOf: Date?
    var suspended: Bool?
}

struct Snapshot {
    var cheapRate: Double
    var peakRate: Double
    var windows: [(from: Int, to: Int)]  // minutes after local midnight
    var dispatches: [Interval]
    var cars: [Car]
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
