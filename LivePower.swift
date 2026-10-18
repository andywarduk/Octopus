// Live power history from a Home Mini, for the live power window: the ranges it offers, the series
// it plots, and the one request behind each.
//
// The menu's single figure rides on the device request (see `deviceQuery`); this is the window's
// own fetch, made only while the window is open.

import Foundation

/// How far back the window looks, and at what grain. Each asks Octopus for a few hundred rows.
enum LivePowerRange: Int, CaseIterable {
    case hour, sixHours, day

    var title: String { ["Last Hour", "6 Hours", "24 Hours"][rawValue] }
    var span: TimeInterval { [3600, 6 * 3600, 24 * 3600][rawValue] }

    /// Ten-second rows for the hour, five-minute buckets beyond it — 360, 72 and 288 slots.
    var grouping: String { self == .hour ? "TEN_SECONDS" : "FIVE_MINUTES" }
    var interval: TimeInterval { self == .hour ? 10 : 300 }

    /// What a slot's figure is. The register resolves whole watt-hours, so a ten-second delta is 0
    /// or 1 and says nothing: those slots plot the meter's `demand`. A five-minute row's `demand`
    /// is one sample at its last reading, so those slots are averaged from their energy instead.
    var plotsDemand: Bool { self == .hour }

    /// How often an open window asks again. The hour's chart moves visibly in a minute; the longer
    /// ones gain one five-minute bucket at a time, so asking more often than that buys nothing.
    var refreshInterval: TimeInterval { self == .hour ? 60 : 300 }

    /// The longest run of missing slots the line is drawn across. A ten-second row goes missing
    /// now and then, and breaking the line at every one makes the hour look broken; a missing
    /// five-minute bucket is a real gap and stays one.
    var bridgedSlots: Int { self == .hour ? 3 : 0 }
}

/// One window's worth of readings, in fixed slots so a missing reading is a gap in place rather
/// than the line closing up over it.
struct LivePowerSeries {
    var range: LivePowerRange
    /// The start of the first slot. Slots are `range.interval` long.
    var start: Date
    /// Watts per slot, nil where nothing was reported.
    var watts: [Double?]
    /// Energy over the window in Wh, summed from the register's deltas. Exact whatever the grain:
    /// the deltas are differences of one register, so their rounding doesn't accumulate.
    var energyWh: Double
    var fetchedAt: Date

    var isEmpty: Bool { watts.allSatisfy { $0 == nil } }

    func slotStart(_ index: Int) -> Date { start.addingTimeInterval(Double(index) * range.interval) }

    var peak: (index: Int, watts: Double)? {
        watts.enumerated().compactMap { item in item.element.map { (item.offset, $0) } }.max { $0.1 < $1.1 }
    }

    /// The newest slot with a reading.
    var latest: (index: Int, watts: Double)? {
        guard let index = watts.lastIndex(where: { $0 != nil }), let value = watts[index] else { return nil }
        return (index, value)
    }

    /// Whether an open window should ask again rather than show this.
    func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) >= range.refreshInterval }
}

/// Lays telemetry rows into the window's slots. Pure, so `--selftest` can cover it.
///
/// `readAt` is the start of each row's bucket. The five-minute window ends at the last whole
/// bucket: the one still filling holds only the minutes so far, and averaged over five it would
/// drag the line's end down. The hour ends at the ten-second slot holding `now`, since a demand
/// reading is complete the moment it is taken.
func liveSeries(rows: Any?, range: LivePowerRange, now: Date) -> LivePowerSeries {
    let interval = range.interval
    let count = Int(range.span / interval)
    let floored = (now.timeIntervalSince1970 / interval).rounded(.down) * interval
    let end = Date(timeIntervalSince1970: range.plotsDemand ? floored + interval : floored)
    let start = end.addingTimeInterval(-range.span)
    var watts = [Double?](repeating: nil, count: count)
    var energy = 0.0
    for case let row as [String: Any] in (rows as? [Any]) ?? [] {
        guard let at = parseDate(row["readAt"]) else { continue }
        let index = Int((at.timeIntervalSince(start) / interval).rounded(.down))
        guard watts.indices.contains(index) else { continue }
        let delta = toDouble(row["consumptionDelta"])
        energy += delta ?? 0
        watts[index] = range.plotsDemand ? toDouble(row["demand"]) : delta.map { $0 * 3600 / interval }
    }
    return LivePowerSeries(range: range, start: start, watts: watts, energyWh: energy, fetchedAt: now)
}

/// One request: the meter's telemetry over the range. An empty answer is not an error — it is what
/// a Mini that has gone quiet looks like, and the window says so.
func fetchLivePower(apiKey: String, meter: LiveMeter, range: LivePowerRange) async throws -> LivePowerSeries {
    let token = try await OctopusSession.shared.token(apiKey: apiKey)
    let now = Date()
    let data = try await gql(
        """
        query($d:String!,$s:DateTime!,$e:DateTime!,$g:TelemetryGrouping){
          smartMeterTelemetry(deviceId:$d,start:$s,end:$e,grouping:$g){readAt demand consumptionDelta}
        }
        """,
        [
            "d": meter.deviceId,
            // A bucket early, so the first slot is whole; a minute late, so a Mac clock behind
            // Octopus's can't cut off the newest row.
            "s": iso8601(now.addingTimeInterval(-range.span - range.interval)),
            "e": iso8601(now.addingTimeInterval(60)),
            "g": range.grouping,
        ], token: token)
    return liveSeries(rows: data["smartMeterTelemetry"], range: range, now: now)
}
