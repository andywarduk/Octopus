// The stacked column chart. Colours are the validated categorical slots 1–3, with steps chosen
// for each appearance rather than flipped automatically.

import Cocoa

enum SeriesColor {
    // Green reads as the cheap one, so off-peak takes the aqua slot and standard the blue.
    // The standing charge is neutral grey on purpose: it isn't a rate, and no categorical hue
    // separates from blue in dark mode at the bottom of the stack. Grey separates by saturation
    // instead — it fails the palette's chroma floor by design, not by accident. Slot 2 orange
    // is the cheap time a smart charge earned outside the off-peak window.
    static let light: [RateBand: NSColor] = [
        .cheap: hexColor("#1baf7a"), .standard: hexColor("#2a78d6"), .standing: hexColor("#8a8a84"),
        .smart: hexColor("#eb6834"),
    ]
    static let dark: [RateBand: NSColor] = [
        .cheap: hexColor("#199e70"), .standard: hexColor("#3987e5"), .standing: hexColor("#9a9a92"),
        .smart: hexColor("#d95926"),
    ]

    static func of(_ band: RateBand, dark isDark: Bool) -> NSColor {
        (isDark ? dark : light)[band] ?? .systemGray
    }
}

/// - Parameters:
///   - withUnit: appends the energy label. Money needs nothing: the £ already says what it is.
///   - energyLabel: kWh for electricity; gas meters may report cubic metres.
func formatUsage(
    _ value: Double, _ unit: UsageUnit, short: Bool = false, withUnit: Bool = false,
    energyLabel: String = "kWh"
) -> String {
    switch unit {
    case .kwh:
        let number = short ? String(format: "%g", value) : String(format: "%.1f", value)
        return withUnit ? number + " " + energyLabel : number
    case .money:
        let pounds = value / 100
        // Axis ticks stay in pounds throughout, so the scale reads consistently from zero up.
        return String(format: short ? "£%g" : "£%.2f", pounds)
    }
}

@MainActor
final class UsageChartView: ChartView {
    var periods: [UsagePeriod] = [] { didSet { needsDisplay = true } }
    var unit: UsageUnit = .kwh { didSet { needsDisplay = true } }
    var granularity: Granularity = .day { didSet { needsDisplay = true } }
    var energyLabel = "kWh" { didSet { needsDisplay = true } }

    override var slotCount: Int { periods.count }

    /// Bands actually drawn, which is not every case: see visibleBands.
    private var bands: [RateBand] { visibleBands(unit) }

    override func draw(_ dirtyRect: NSRect) {
        guard beginDrawing(dirtyRect) else { return }
        // Top leaves room for the legend plus a cap label above a column that nearly fills the plot.
        let plot = plotArea(top: 46)
        let maxTotal = periods.map { $0.total(unit, bands) }.max() ?? 1
        let (axisMax, axisStep) = axisScale(maxTotal)

        slotWidth = plot.width / CGFloat(periods.count)
        drawGrid(plot: plot, axisMax: axisMax, step: axisStep)
        if granularity == .halfHour { drawTimeGrid(plot: plot, starts: periods.map(\.start)) }
        drawColumns(plot: plot, axisMax: axisMax)
        drawLegend()
        plotRect = plot
        if let hoverIndex, hoverIndex < periods.count { drawTooltip(for: hoverIndex, plot: plot) }
    }

    private func drawGrid(plot: CGRect, axisMax: Double, step: Double) {
        // Recessive: hairlines and muted ink, so the data stays in front.
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let lines = max(1, Int((axisMax / step).rounded()))
        for index in 0...lines {
            let value = step * Double(index)
            let fraction = value / axisMax
            let y = plot.minY + plot.height * fraction
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y.rounded() + 0.5))
            line.line(to: CGPoint(x: plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            label(
                formatUsage(value, unit, short: true),
                at: CGPoint(x: plot.minX - 8, y: y - 6), size: 10, color: .tertiaryLabelColor, align: .right)
        }
    }

    private func drawColumns(plot: CGRect, axisMax: Double) {
        let slot = slotWidth
        // Daily columns sit apart; half-hourly bars always meet, as one strip at any width. A gap
        // once they grew wide read as a cap on how wide a bar could get.
        let nominalWidth = granularity == .day ? min(46, slot * 0.66) : slot
        let segmentGap: CGFloat = nominalWidth >= 6 ? 2 : 0
        let showCaps = granularity == .day

        func column(_ index: Int) -> (left: CGFloat, width: CGFloat) {
            if granularity == .day {
                let centre = plot.minX + slot * (CGFloat(index) + 0.5)
                return (centre - nominalWidth / 2, nominalWidth)
            }
            // Snap both edges to the pixel grid. Rounding only the origin leaves a sub-pixel
            // sliver of background between neighbours, which draws as a hairline.
            let edge = snapToPixel(plot.minX + slot * CGFloat(index))
            let nextEdge = snapToPixel(plot.minX + slot * CGFloat(index + 1))
            return (edge, max(1, nextEdge - edge))
        }

        if let hoverIndex, hoverIndex < periods.count {
            let (left, width) = column(hoverIndex)
            drawHoverHighlight(left: left, width: width, plot: plot)
        }

        for (index, period) in periods.enumerated() {
            let centre = plot.minX + slot * (CGFloat(index) + 0.5)
            let (left, width) = column(index)

            if !period.hasData {
                // A dash on the baseline: clearly not a zero-height bar.
                NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(rect: CGRect(x: left, y: plot.minY, width: width, height: 2)).fill()
                continue
            }

            let drawn = bands.filter { period.value($0, unit) > 0 }
            var y = plot.minY
            for (position, band) in drawn.enumerated() {
                let value = period.value(band, unit)
                let full = CGFloat(value / axisMax) * plot.height
                let isTop = position == drawn.count - 1
                // The gap is taken off the top of every segment but the last, so the stack's
                // total height still reads true against the axis.
                let height = max(1, full - (isTop ? 0 : segmentGap))
                let rect = CGRect(x: left, y: y, width: width, height: height)
                // Faded where the Home Mini stands in for figures Octopus hasn't published: the
                // same band, so it still reads as the same kind of use, but plainly not final. The
                // legend and the tooltip say so in words, so the shade never carries it alone.
                let shade = SeriesColor.of(band, dark: isDark)
                (period.provisional ? shade.withAlphaComponent(provisionalAlpha) : shade).setFill()
                // Only the data end is rounded; everything below stays square on the baseline.
                // Half-hourly bars meet, so rounding each top would notch the strip between them.
                let path = granularity == .day && isTop && height > 4 && width >= 8
                    ? roundedTop(rect, radius: 4) : NSBezierPath(rect: rect)
                path.fill()
                if hoverIndex == index {
                    // The bar itself is marked, not only the space around it: in the half-hourly
                    // strip the neighbours hide the background highlight almost entirely.
                    hoverTint(over: SeriesColor.of(band, dark: isDark)).setFill()
                    path.fill()
                }
                y += full
            }

            // Columns carry their value on the cap; the per-band numbers live in the legend
            // and the hover tooltip rather than on every segment.
            if showCaps, period.total(unit) > 0 {
                label(
                    formatUsage(period.total(unit), unit), at: CGPoint(x: centre, y: y + 4), size: 10,
                    color: .secondaryLabelColor, align: .centre)
            }
        }
        drawTimeAxis(plot: plot, slot: slot)
    }

    /// Day names under daily columns; under half-hourly bars, one name per day plus a boundary tick.
    private func drawTimeAxis(plot: CGRect, slot: CGFloat) {
        if granularity == .day {
            for (index, period) in periods.enumerated() {
                label(
                    formatted(period.start, "EEE", tz),
                    at: CGPoint(x: plot.minX + slot * (CGFloat(index) + 0.5), y: plot.minY - 20), size: 10,
                    color: .secondaryLabelColor, align: .centre)
            }
            return
        }

        let cal = calendar(tz)
        var runStart = 0
        for index in 0...periods.count {
            let isBoundary = index == periods.count
                || !cal.isDate(periods[index].start, inSameDayAs: periods[runStart].start)
            guard isBoundary else { continue }
            let from = plot.minX + slot * CGFloat(runStart)
            let to = plot.minX + slot * CGFloat(index)
            if to - from > 26 {
                label(
                    formatted(periods[runStart].start, "EEE", tz),
                    at: CGPoint(x: (from + to) / 2, y: plot.minY - 20), size: 10,
                    color: .secondaryLabelColor, align: .centre)
            }
            runStart = index
        }
    }

    private func roundedTop(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.appendArc(
            withCenter: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
            startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.appendArc(
            withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
            startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }

    /// How strongly a provisional column is drawn: light enough to read as not final, while the
    /// band's hue still shows through against both surfaces.
    private var provisionalAlpha: CGFloat { 0.45 }

    private func drawLegend() {
        // Always present for three series, and it carries each band's weekly total so the
        // numbers are readable as text and not only as colour.
        var x: CGFloat = 52
        let y = bounds.height - 20
        func entry(_ text: String, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y + 1, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            label(text, at: CGPoint(x: x + 14, y: y - 1), size: 10, color: .secondaryLabelColor)
            x += 14 + text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width + 16
        }
        for band in bands {
            let total = periods.reduce(0) { $0 + $1.value(band, unit) }
            guard total > 0 else { continue }
            entry("\(band.rawValue) \(formatUsage(total, unit, withUnit: true, energyLabel: energyLabel))",
                  SeriesColor.of(band, dark: isDark))
        }
        // The faded shade is a second encoding on top of the bands, so it gets its own key, in the
        // first energy band drawn — for gas the only one. Not the standing charge, which comes
        // first in the £ view: its grey faded to near the surface and the key all but vanished.
        if periods.contains(where: \.provisional),
            let band = bands.first(where: { band in
                band.isConsumption && periods.contains { $0.value(band, unit) > 0 }
            })
        {
            entry("Home Mini, not yet published", SeriesColor.of(band, dark: isDark).withAlphaComponent(provisionalAlpha))
        }
    }

    private func drawTooltip(for index: Int, plot: CGRect) {
        let period = periods[index]
        var heading = granularity == .day
            ? formatted(period.start, "EEE d MMM", tz)
            : "\(formatted(period.start, "EEE d MMM HH:mm", tz))–\(formatted(period.end, "HH:mm", tz))"
        if period.hasData || granularity == .halfHour {
            heading += "  ·  \(formatUsage(period.total(unit, bands), unit, withUnit: true, energyLabel: energyLabel))"
        }
        // The kWh view carries the cost too. It is the whole cost, standing charge included, so it
        // matches the same period's total in the £ view; the standing charge gets its own line
        // below so the band costs still add up to it.
        let standing = period.value(.standing, .money)
        if unit == .kwh, period.hasData {
            heading += "  ·  \(formatUsage(period.total(.money), .money, withUnit: true))"
        }
        var lines = [TooltipLine(heading)]
        if !period.hasData {
            lines.append(TooltipLine("No data yet — Octopus publishes about two days behind"))
        }
        if period.provisional {
            // A day can be part published, part stand-in; a half hour is one or the other.
            let halfHours = Int((period.end.timeIntervalSince(period.start) / 1800).rounded())
            lines.append(TooltipLine(
                period.homeMiniHalfHours >= halfHours
                    ? "From the Home Mini — Octopus hasn't published this yet"
                    : "\(period.homeMiniHalfHours) of \(halfHours) half hours from the Home Mini, not yet published"))
        }
        for band in bands where period.value(band, unit) > 0 {
            var text = "\(band.rawValue): \(formatUsage(period.value(band, unit), unit, withUnit: true, energyLabel: energyLabel))"
            // The rate explains a kWh figure; beside a money figure it is arithmetic the reader
            // didn't ask for, so the £ view shows only what the band cost.
            if unit == .kwh, let price = period.price(band) {
                // What it came to as well: the billed amount, which the rate was derived from.
                text += String(format: " @ %.2fp", price)
                    + " = \(formatUsage(period.value(band, .money), .money, withUnit: true))"
            }
            lines.append(TooltipLine(text, SeriesColor.of(band, dark: isDark)))
        }
        if unit == .kwh, standing > 0 {
            lines.append(TooltipLine(
                "\(RateBand.standing.rawValue): \(formatUsage(standing, .money, withUnit: true))",
                SeriesColor.of(.standing, dark: isDark)))
        }
        // No swatch: it lists overnight runs too, whose energy is off-peak green, not smart-charge orange.
        if let smart = smartChargeText(period, granularity: granularity, tz: tz, periods: periods) {
            lines.append(TooltipLine(smart))
        }
        if period.hasData, period.total(unit, bands) == 0 { lines.append(TooltipLine("No usage")) }

        drawTooltipBox(
            lines, anchorX: plot.minX + slotWidth * (CGFloat(index) + 0.5), slotWidth: slotWidth,
            plot: plot, in: bounds)
    }
}

// MARK: - Offscreen render, for eyeballing the layout without launching the app

@MainActor
func renderUsageChart(
    periods: [UsagePeriod], unit: UsageUnit, granularity: Granularity, tz: TimeZone, dark: Bool,
    size: CGSize, hover: Int? = nil, placeholder: String? = nil, to path: String
) {
    let view = UsageChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // The periods' own zone, not the view's default of the Mac's, or the labels depend on where
    // the render ran.
    view.tz = tz
    view.periods = periods
    view.granularity = granularity
    view.unit = unit
    view.placeholder = placeholder
    view.previewHover(hover)
    writePNG(renderOffscreen(view, dark: dark), to: path)
}

/// A seeded gas week whose unpublished tail is filled from a Home Mini, through the same
/// `homeMiniFill` the app uses — the heating on mornings and evenings, one rate, and the last day
/// and a half standing in for what Octopus hasn't published yet.
func sampleGasWeek(tz: TimeZone, now: Date) -> UsageSeries {
    let cal = calendar(tz)
    guard let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) else {
        return UsageSeries()
    }
    var generator = SeededGenerator(seed: 20_261_018)
    let price = 8.1676
    var buckets: [UsageBucket] = []
    var standing: [(start: Date, pence: Double)] = []
    var telemetry: [[String: Any]] = []
    for slot in 0..<(7 * 48) {
        let start = weekStart.addingTimeInterval(Double(slot) * 1800)
        let hour = Double(cal.component(.hour, from: start)) + Double(cal.component(.minute, from: start)) / 60
        let heating = (6.5..<8.5).contains(hour) || (17..<22).contains(hour)
        let kwh = heating ? 2.2 + Double(generator.next() % 120) / 100 : (generator.next() % 6 == 0 ? 0.4 : 0)
        // Published to 01:00 on the sixth day, as Octopus runs about two days behind.
        if slot < 5 * 48 + 2 {
            standing.append((start, 1.03))
            if kwh > 0 {
                buckets.append(UsageBucket(
                    start: start, label: "CONSUMPTION_CHARGE", kwh: kwh, pence: kwh * price, pricePerUnit: price))
            }
        } else if start.addingTimeInterval(1800) <= now {
            telemetry.append([
                "readAt": iso8601(start), "consumptionDelta": String(format: "%.2f", kwh * 1000),
                "costDeltaWithTax": String(format: "%.4f", kwh * price),
            ])
        }
    }
    var series = UsageSeries(
        buckets: buckets, standing: standing, tz: tz, from: weekStart,
        to: weekStart.addingTimeInterval(7 * 86400), readings: standing.count)
    let fill = homeMiniFill(
        rows: telemetry, missing: Set(unpublishedHalfHours(series, now: now)), standingPerHalfHour: 1.03,
        fallbackPrice: price)
    series.buckets += fill.buckets
    series.standing += fill.standing
    series.homeMiniSlots = fill.slots
    return series
}

/// Deterministic, so the demo images and the hairline check are repeatable run to run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// A week shaped like a real one: a small household base load, plus a 7 kW charge overnight and
/// on two afternoons. At 7 kW a half hour is 3.5 kWh, so the charging blocks are flat-topped.
func sampleUsageWeek(tz: TimeZone, now: Date = Date()) -> UsageSeries {
    let cal = calendar(tz)
    guard let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) else {
        return UsageSeries()
    }
    let chargerKw = 7.0
    let perHalfHour = chargerKw / 2
    var buckets: [UsageBucket] = []
    var standing: [(start: Date, pence: Double)] = []
    var generator = SeededGenerator(seed: 20_260_920)
    // How many hours the car charges each night, from 23:30.
    let chargeHours: [Double] = [4, 2.5, 5, 3, 5.5, 1.5, 3]

    for slot in 0..<(7 * 48) {
        let start = weekStart.addingTimeInterval(Double(slot) * 1800)
        let hour = Double(cal.component(.hour, from: start)) + Double(cal.component(.minute, from: start)) / 60
        let day = slot / 48
        // Octopus publishes about two days behind, so the tail of the week has nothing at all.
        guard day < 5 || (day == 5 && hour < 1) else { continue }
        standing.append((start, 1.03))
        guard hour < 9 || hour >= 11 || day != 3 else { continue }  // a gap with no readings

        // Hours since the charge window opened at 23:30 the evening before.
        let sinceWindow = hour >= 23.5 ? hour - 23.5 : hour + 0.5
        let overnight = hour >= 23.5 || hour < 5.5
        let nightIndex = hour >= 23.5 ? min(day + 1, 6) : day
        let charging = overnight && sinceWindow < chargeHours[nightIndex]
        let dispatch = (day == 1 || day == 4) && hour >= 13 && hour < 14.5

        let base = Double.random(in: 0.08...0.32, using: &generator)
        var entries: [(String, Double, Double)] = []
        if charging {
            // Mirrors the real data: a fixed slice goes to the EV bucket, the remainder to the
            // household bucket at the same off-peak price.
            entries.append(("CONSUMPTION_CHARGE_EV_DEVICE_OFF_PEAK_H", 6.89997, 2.611))
            entries.append(("CONSUMPTION_CHARGE_ECO7_NIGHT_H", 6.89997, perHalfHour - 2.611 + base))
        } else if dispatch {
            entries.append(("CONSUMPTION_CHARGE_EV_DEVICE_OFF_PEAK_H", 6.89997, 2.611))
            entries.append(("CONSUMPTION_CHARGE_ECO7_NIGHT_H", 6.89997, perHalfHour - 2.611 + base))
        } else if overnight {
            entries.append(("CONSUMPTION_CHARGE_ECO7_NIGHT_H", 6.89997, base))
        } else {
            entries.append(("CONSUMPTION_CHARGE_ECO7_DAY_H", 30.37136, base))
        }
        for (label, price, kwh) in entries {
            buckets.append(UsageBucket(start: start, label: label, kwh: kwh, pence: kwh * price, pricePerUnit: price))
        }
    }
    return UsageSeries(
        buckets: buckets, standing: standing, tz: tz, from: weekStart,
        to: weekStart.addingTimeInterval(7 * 86400))
}

/// Counts one-pixel background slivers flanked by bar colour — the hairlines that appear when
/// adjacent bars don't quite meet. Used by --chartdemo to check the fix without a screenshot.
@MainActor
func countHairlines(periods: [UsagePeriod], tz: TimeZone, dark: Bool, size: CGSize) -> Int {
    let view = UsageChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.tz = tz
    view.granularity = .halfHour
    view.periods = periods
    guard let rep = renderOffscreen(view, dark: dark) else { return -1 }
    let surface = chartSurface(dark: dark)

    let palette = (dark ? SeriesColor.dark : SeriesColor.light).values.map {
        $0.usingColorSpace(.sRGB)!
    } + [surface.usingColorSpace(.sRGB)!]

    /// A pixel that matches neither the surface nor any band colour is a partially covered edge:
    /// a fractional bar boundary antialiased against the background, which reads as a fine line.
    func isBlend(_ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return !palette.contains { known in
            abs(c.redComponent - known.redComponent) < 0.02
                && abs(c.greenComponent - known.greenComponent) < 0.02
                && abs(c.blueComponent - known.blueComponent) < 0.02
        }
    }

    // The row immediately above the baseline: every bar with any usage covers it, so a
    // blended pixel here is a seam between neighbours rather than the top of a short bar.
    var hairlines = 0
    var columns: Set<Int> = []
    // Must match the bottom inset in draw(), or the scan lands below the bars.
    let baselineY = Int(size.height) - Int(plotBottomInset)
    // Skip slots with no data: their "not published" dash is a blend by design, not a seam.
    let plotMinX = 52.0
    let slot = (size.width - plotMinX - 14) / CGFloat(max(1, periods.count))
    func hasData(atX x: Int) -> Bool {
        let index = Int((CGFloat(x) - plotMinX) / slot)
        guard index >= 0, index < periods.count else { return false }
        return periods[index].hasData
    }

    for y in (baselineY - 2)...(baselineY - 1) {
        for x in 60..<(Int(size.width) - 20) where hasData(atX: x) && isBlend(x, y) {
            hairlines += 1
            columns.insert(x)
        }
    }
    if !columns.isEmpty { print("  hairline x positions: \(columns.sorted())") }
    return hairlines
}
