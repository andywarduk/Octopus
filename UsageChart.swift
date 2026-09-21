// The stacked column chart. Colours are the validated categorical slots 1–3, with steps chosen
// for each appearance rather than flipped automatically.

import Cocoa

func hexColor(_ hex: String) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1)
}

enum SeriesColor {
    // Categorical slots 1, 2, 3 in fixed order: blue, orange, aqua.
    static let light: [RateBand: NSColor] = [
        .cheap: hexColor("#2a78d6"), .smartCharge: hexColor("#eb6834"), .standard: hexColor("#1baf7a"),
    ]
    static let dark: [RateBand: NSColor] = [
        .cheap: hexColor("#3987e5"), .smartCharge: hexColor("#d95926"), .standard: hexColor("#199e70"),
    ]

    static func of(_ band: RateBand, dark isDark: Bool) -> NSColor {
        (isDark ? dark : light)[band] ?? .systemGray
    }
}

/// Rounds an axis maximum up to a round number. The ladder is fine enough that a column never
/// fills much less than about three quarters of the plot, and every step still quarters cleanly.
func niceMax(_ value: Double) -> Double {
    guard value > 0 else { return 1 }
    let magnitude = pow(10, (log10(value)).rounded(.down))
    let normalised = value / magnitude
    let step = [1.0, 1.5, 2, 3, 4, 5, 6, 8, 10].first { normalised <= $0 } ?? 10
    return step * magnitude
}

func formatUsage(_ value: Double, _ unit: UsageUnit, short: Bool = false) -> String {
    switch unit {
    case .kwh: return short ? String(format: "%g", value) : String(format: "%.1f", value)
    case .money:
        let pounds = value / 100
        // Axis ticks stay in pounds throughout, so the scale reads consistently from zero up.
        return String(format: short ? "£%g" : "£%.2f", pounds)
    }
}

@MainActor
final class UsageChartView: NSView {
    var periods: [UsagePeriod] = [] { didSet { needsDisplay = true } }
    var unit: UsageUnit = .kwh { didSet { needsDisplay = true } }
    var granularity: Granularity = .day { didSet { needsDisplay = true } }
    var tz: TimeZone = .current
    private var hoverIndex: Int?
    private var plotRect: CGRect = .zero
    private var slotWidth: CGFloat = 0

    override var isFlipped: Bool { false }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Hit the whole slot, not the drawn bar: at half-hourly width the bars are far too
        // thin to aim at.
        var index: Int?
        if slotWidth > 0, plotRect.insetBy(dx: 0, dy: -8).contains(point) {
            let slot = Int((point.x - plotRect.minX) / slotWidth)
            if slot >= 0 && slot < periods.count { index = slot }
        }
        if index != hoverIndex {
            hoverIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        guard !periods.isEmpty else { return }

        let left: CGFloat = 52, right: CGFloat = 14, top: CGFloat = 30, bottom: CGFloat = 26
        let plot = CGRect(
            x: left, y: bottom, width: max(10, bounds.width - left - right),
            height: max(10, bounds.height - top - bottom))
        let maxTotal = periods.map { $0.total(unit) }.max() ?? 1
        let axisMax = niceMax(maxTotal)

        drawGrid(plot: plot, axisMax: axisMax)
        drawColumns(plot: plot, axisMax: axisMax)
        drawLegend()
        plotRect = plot
        if let hoverIndex, hoverIndex < periods.count { drawTooltip(for: hoverIndex, plot: plot) }
    }

    enum Align {
        case left, right, centre
    }

    private func label(
        _ text: String, at point: CGPoint, size: CGFloat, color: NSColor, align: Align = .left
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        var origin = point
        switch align {
        case .left: break
        case .right: origin.x -= string.size().width
        case .centre: origin.x -= string.size().width / 2
        }
        string.draw(at: origin)
    }

    private func drawGrid(plot: CGRect, axisMax: Double) {
        // Recessive: hairlines and muted ink, so the data stays in front.
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        for step in 0...4 {
            let fraction = Double(step) / 4
            let y = plot.minY + plot.height * fraction
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y.rounded() + 0.5))
            line.line(to: CGPoint(x: plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            label(
                formatUsage(axisMax * fraction, unit, short: true),
                at: CGPoint(x: plot.minX - 8, y: y - 6), size: 10, color: .tertiaryLabelColor, align: .right)
        }
    }

    private func drawColumns(plot: CGRect, axisMax: Double) {
        let slot = plot.width / CGFloat(periods.count)
        slotWidth = slot
        // Daily columns sit apart; half-hourly bars are a contiguous strip, where a gap would
        // cost more width than it buys in separation.
        let barGap: CGFloat = granularity == .day || slot < 6 ? 0 : 2
        let nominalWidth = granularity == .day ? min(46, slot * 0.66) : slot - barGap
        let segmentGap: CGFloat = nominalWidth >= 6 ? 2 : 0
        let showCaps = granularity == .day

        for (index, period) in periods.enumerated() {
            let centre = plot.minX + slot * (CGFloat(index) + 0.5)
            let left: CGFloat
            let width: CGFloat
            if granularity == .day {
                width = nominalWidth
                left = centre - width / 2
            } else {
                // Snap both edges to the pixel grid. Rounding only the origin leaves a sub-pixel
                // sliver of background between neighbours, which draws as a hairline.
                let edge = (plot.minX + slot * CGFloat(index)).rounded()
                let nextEdge = (plot.minX + slot * CGFloat(index + 1)).rounded()
                left = edge
                width = max(1, nextEdge - edge - barGap)
            }

            if hoverIndex == index {
                NSColor.secondaryLabelColor.withAlphaComponent(0.09).setFill()
                NSBezierPath(
                    roundedRect: CGRect(x: left - 3, y: plot.minY - 3, width: width + 6, height: plot.height + 6),
                    xRadius: 4, yRadius: 4
                ).fill()
            }

            let bands = RateBand.allCases.filter { period.value($0, unit) > 0 }
            var y = plot.minY
            for (position, band) in bands.enumerated() {
                let value = period.value(band, unit)
                let full = CGFloat(value / axisMax) * plot.height
                let isTop = position == bands.count - 1
                // The gap is taken off the top of every segment but the last, so the stack's
                // total height still reads true against the axis.
                let height = max(1, full - (isTop ? 0 : segmentGap))
                let rect = CGRect(x: left, y: y, width: width, height: height)
                SeriesColor.of(band, dark: isDark).setFill()
                // Only the data end is rounded; everything below stays square on the baseline.
                let path = isTop && height > 4 && width >= 8
                    ? roundedTop(rect, radius: 4) : NSBezierPath(rect: rect)
                path.fill()
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
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_GB")
        dayFormat.timeZone = tz
        dayFormat.dateFormat = "EEE"

        if granularity == .day {
            for (index, period) in periods.enumerated() {
                label(
                    dayFormat.string(from: period.start),
                    at: CGPoint(x: plot.minX + slot * (CGFloat(index) + 0.5), y: plot.minY - 16), size: 10,
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
                    dayFormat.string(from: periods[runStart].start),
                    at: CGPoint(x: (from + to) / 2, y: plot.minY - 16), size: 10,
                    color: .secondaryLabelColor, align: .centre)
            }
            if index < periods.count {
                NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
                let tick = NSBezierPath()
                tick.move(to: CGPoint(x: to.rounded() + 0.5, y: plot.minY - 4))
                tick.line(to: CGPoint(x: to.rounded() + 0.5, y: plot.minY))
                tick.lineWidth = 1
                tick.stroke()
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

    private func drawLegend() {
        // Always present for three series, and it carries each band's weekly total so the
        // numbers are readable as text and not only as colour.
        var x: CGFloat = 52
        let y = bounds.height - 20
        for band in RateBand.allCases {
            let total = periods.reduce(0) { $0 + $1.value(band, unit) }
            guard total > 0 else { continue }
            SeriesColor.of(band, dark: isDark).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y + 1, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            let text = "\(band.rawValue) \(formatUsage(total, unit))"
            label(text, at: CGPoint(x: x + 14, y: y - 1), size: 10, color: .secondaryLabelColor)
            x += 14 + text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width + 16
        }
    }

    private func drawTooltip(for index: Int, plot: CGRect) {
        let period = periods[index]
        let heading: String
        if granularity == .day {
            heading = "\(formatted(period.start, "EEE d MMM", tz))  ·  \(formatUsage(period.total(unit), unit))"
        } else {
            heading = "\(formatted(period.start, "EEE d MMM HH:mm", tz))–\(formatted(period.end, "HH:mm", tz))"
                + "  ·  \(formatUsage(period.total(unit), unit))"
        }
        var lines = [heading]
        for band in RateBand.allCases where period.value(band, unit) > 0 {
            lines.append("\(band.rawValue): \(formatUsage(period.value(band, unit), unit))")
        }
        if period.total(unit) == 0 { lines.append("No usage") }
        if unit == .money, granularity == .day, period.standingPence > 0 {
            lines.append("Standing: \(formatUsage(period.standingPence, .money))")
        }

        let font = NSFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let width = lines.map { $0.size(withAttributes: attributes).width }.max() ?? 80
        let height = CGFloat(lines.count) * 15 + 10
        let anchorX = plot.minX + slotWidth * (CGFloat(index) + 0.5)
        var box = CGRect(x: anchorX - (width + 16) / 2, y: plot.maxY - height, width: width + 16, height: height)
        box.origin.x = min(max(box.minX, 4), bounds.width - box.width - 4)

        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        for (row, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: attributes)
                .draw(at: CGPoint(x: box.minX + 8, y: box.maxY - 17 - CGFloat(row) * 15))
        }
    }
}

// MARK: - Offscreen render, for eyeballing the layout without launching the app

@MainActor
func renderUsageChart(
    periods: [UsagePeriod], unit: UsageUnit, granularity: Granularity, dark: Bool, size: CGSize,
    to path: String
) {
    let view = UsageChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.periods = periods
    view.granularity = granularity
    view.unit = unit
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    // Paint the chart surface first; the view itself draws on a clear background.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (dark ? hexColor("#1a1a19") : hexColor("#fcfcfb")).setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
func sampleUsageWeek(tz: TimeZone) -> UsageSeries {
    let cal = calendar(tz)
    guard let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date())) else {
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
            entries.append(("CONSUMPTION_CHARGE_ECO7_NIGHT_H", 6.89997, perHalfHour + base))
        } else if dispatch {
            entries.append(("CONSUMPTION_CHARGE_EV_DEVICE_OFF_PEAK_H", 6.89997, perHalfHour))
            // The house is still on the standard rate while the car charges on a dispatch.
            entries.append(("CONSUMPTION_CHARGE_ECO7_DAY_H", 30.37136, base))
        } else if overnight {
            entries.append(("CONSUMPTION_CHARGE_ECO7_NIGHT_H", 6.89997, base))
        } else {
            entries.append(("CONSUMPTION_CHARGE_ECO7_DAY_H", 30.37136, base))
        }
        for (label, price, kwh) in entries {
            buckets.append(UsageBucket(start: start, label: label, kwh: kwh, pence: kwh * price, pricePerUnit: price))
        }
    }
    return UsageSeries(buckets: buckets, standing: standing, tz: tz)
}

/// Counts one-pixel background slivers flanked by bar colour — the hairlines that appear when
/// adjacent bars don't quite meet. Used by --chartdemo to check the fix without a screenshot.
@MainActor
func countHairlines(periods: [UsagePeriod], dark: Bool, size: CGSize) -> Int {
    let view = UsageChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.granularity = .halfHour
    view.periods = periods
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
    let surface = dark ? hexColor("#1a1a19") : hexColor("#fcfcfb")
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    surface.setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)

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
    let baselineY = Int(size.height) - 26
    for y in (baselineY - 2)...(baselineY - 1) {
        for x in 60..<(Int(size.width) - 20) where isBlend(x, y) {
            hairlines += 1
            columns.insert(x)
        }
    }
    if !columns.isEmpty { print("  hairline x positions: \(columns.sorted())") }
    return hairlines
}
