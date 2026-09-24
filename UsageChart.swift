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
    // Green reads as the cheap one, so off-peak takes the aqua slot and standard the blue.
    // The standing charge is neutral grey on purpose: it isn't a rate, and no categorical hue
    // separates from blue in dark mode at the bottom of the stack. Grey separates by saturation
    // instead — it fails the palette's chroma floor by design, not by accident. Slot 2 orange
    // marks a smart charge, which sits under the axis because it isn't a price either.
    static let light: [RateBand: NSColor] = [
        .cheap: hexColor("#1baf7a"), .standard: hexColor("#2a78d6"), .standing: hexColor("#8a8a84"),
    ]
    static let dark: [RateBand: NSColor] = [
        .cheap: hexColor("#199e70"), .standard: hexColor("#3987e5"), .standing: hexColor("#9a9a92"),
    ]
    static func smart(dark isDark: Bool) -> NSColor {
        isDark ? hexColor("#d95926") : hexColor("#eb6834")
    }

    static func of(_ band: RateBand, dark isDark: Bool) -> NSColor {
        (isDark ? dark : light)[band] ?? .systemGray
    }
}

/// Picks a round gridline step first, then the axis maximum as a whole number of those steps.
/// Choosing the maximum first and quartering it gives ticks like 1.25 / 2.5 / 3.75.
/// Steps ascend, so the first one needing six lines or fewer is the finest that stays readable.
func axisScale(_ maxValue: Double) -> (max: Double, step: Double) {
    guard maxValue > 0, maxValue.isFinite else { return (1, 1) }
    for power in -4...12 {
        for base in [1.0, 2, 2.5, 5] {
            let step = base * pow(10, Double(power))
            let divisions = (maxValue / step).rounded(.up)
            if divisions <= 6 { return (divisions * step, step) }
        }
    }
    return (maxValue, maxValue)
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

/// Space under the plot for the smart-charge markers, the boundary ticks and the day labels.
let plotBottomInset: CGFloat = 30

// MARK: - Shared tooltip
//
// Both charts draw the same box, so it lives here with the other pieces they share.

/// One row of a tooltip. A `color` draws the swatch that identifies which series the row is
/// about — the same colour as the mark it describes, so the row and the bar are tied together
/// without the reader having to match a position against the legend.
struct TooltipLine {
    var text: String
    var color: NSColor?

    init(_ text: String, _ color: NSColor? = nil) {
        self.text = text
        self.color = color
    }
}

/// Draws the tooltip beside the hovered slot, never over it: centring the box hides the column's
/// own cap label. Falls to the other side, then clamps, rather than running off the edge.
@MainActor
func drawTooltipBox(_ lines: [TooltipLine], anchorX: CGFloat, slotWidth: CGFloat, plot: CGRect, in bounds: CGRect) {
    guard !lines.isEmpty else { return }
    let font = NSFont.systemFont(ofSize: 11)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    // One gutter for every row once any row has a swatch, so the text stays in a single column
    // rather than stepping in and out around the rows that don't.
    let gutter: CGFloat = lines.contains { $0.color != nil } ? 15 : 0
    let width = (lines.map { $0.text.size(withAttributes: attributes).width }.max() ?? 80) + gutter
    let height = CGFloat(lines.count) * 15 + 10
    let boxWidth = width + 16
    let gap = max(8, slotWidth / 2 + 8)
    var originX = anchorX + gap
    if originX + boxWidth > bounds.width - 4 { originX = anchorX - gap - boxWidth }
    originX = min(max(originX, 4), bounds.width - boxWidth - 4)
    let box = CGRect(x: originX, y: plot.maxY - height, width: boxWidth, height: height)

    NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
    let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
    path.fill()
    NSColor.separatorColor.setStroke()
    path.stroke()

    for (row, line) in lines.enumerated() {
        let baseline = box.maxY - 17 - CGFloat(row) * 15
        if let color = line.color {
            color.setFill()
            NSBezierPath(
                roundedRect: CGRect(x: box.minX + 8, y: baseline + 2, width: 9, height: 9),
                xRadius: 2, yRadius: 2
            ).fill()
        }
        NSAttributedString(string: line.text, attributes: attributes)
            .draw(at: CGPoint(x: box.minX + 8 + gutter, y: baseline))
    }
}

@MainActor
final class UsageChartView: NSView {
    var periods: [UsagePeriod] = [] { didSet { needsDisplay = true } }
    var unit: UsageUnit = .kwh { didSet { needsDisplay = true } }
    var granularity: Granularity = .day { didSet { needsDisplay = true } }
    /// Shown centred when there is nothing to plot, so the plot area is never just blank.
    var placeholder: String? { didSet { needsDisplay = true } }
    var energyLabel = "kWh" { didSet { needsDisplay = true } }
    var tz: TimeZone = .current
    private var hoverIndex: Int?
    private var plotRect: CGRect = .zero
    private var slotWidth: CGFloat = 0

    override var isFlipped: Bool { false }

    /// Device pixels per point: 2 on a Retina display, 1 offscreen where there is no window.
    private var pixelScale: CGFloat { window?.backingScaleFactor ?? 1 }

    /// Snaps to the device pixel grid rather than to whole points. Points are two device pixels
    /// on Retina, so rounding to them makes half-hourly bars alternate 1pt and 2pt — a visible
    /// 2:1 difference in thickness. Snapping finer keeps edges crisp and the widths closer.
    private func snapToPixel(_ value: CGFloat) -> CGFloat {
        (value * pixelScale).rounded() / pixelScale
    }

    /// Bands actually drawn, which is not every case: see visibleBands.
    private var bands: [RateBand] { visibleBands(unit, granularity) }

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

    /// Forces the hover state, so the offscreen renderer can show a tooltip.
    func previewHover(_ index: Int?) {
        hoverIndex = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        guard !periods.isEmpty else {
            if let placeholder {
                label(
                    placeholder, at: CGPoint(x: bounds.midX, y: bounds.midY - 6), size: 12,
                    color: .tertiaryLabelColor, align: .centre)
            }
            return
        }

        // Top leaves room for the legend plus a cap label above a column that nearly fills the plot.
        let left: CGFloat = 52, right: CGFloat = 14, top: CGFloat = 46
        let bottom = plotBottomInset
        let plot = CGRect(
            x: left, y: bottom, width: max(10, bounds.width - left - right),
            height: max(10, bounds.height - top - bottom))
        let maxTotal = periods.map { $0.total(unit, bands) }.max() ?? 1
        let (axisMax, axisStep) = axisScale(maxTotal)

        slotWidth = plot.width / CGFloat(periods.count)
        drawGrid(plot: plot, axisMax: axisMax, step: axisStep)
        drawTimeGrid(plot: plot)
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

    /// Vertical rules for half-hourly bars: strong at midnight, faint at noon. Drawn before the
    /// columns so it stays behind the data.
    private func drawTimeGrid(plot: CGRect) {
        guard granularity == .halfHour else { return }
        let cal = calendar(tz)
        for (index, period) in periods.enumerated() where index > 0 {
            let parts = cal.dateComponents([.hour, .minute], from: period.start)
            guard parts.minute == 0, parts.hour == 0 || parts.hour == 12 else { continue }
            let isMidnight = parts.hour == 0
            // Recessive: about the weight of the horizontal rules, with noon fainter still.
            // Noon is dashed as well as fainter, so the two read apart without opacity alone —
            // which is what lets the dashes stay this light.
            NSColor.separatorColor.withAlphaComponent(isMidnight ? 0.45 : 0.2).setStroke()
            let line = NSBezierPath()
            let x = (plot.minX + slotWidth * CGFloat(index)).rounded() + 0.5
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            if !isMidnight { line.setLineDash([4, 4], count: 2, phase: 0) }
            line.stroke()
        }
    }

    private func drawColumns(plot: CGRect, axisMax: Double) {
        let slot = slotWidth
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
                let edge = snapToPixel(plot.minX + slot * CGFloat(index))
                let nextEdge = snapToPixel(plot.minX + slot * CGFloat(index + 1))
                left = edge
                width = max(1, nextEdge - edge - barGap)
            }

            if hoverIndex == index {
                // Pad by a fraction of the bar, not a fixed amount: 3px either side of a 1.6px
                // half-hourly bar makes the highlight wider than the thing it marks.
                let pad = min(3, max(0.5, width / 3))
                NSColor.secondaryLabelColor.withAlphaComponent(0.09).setFill()
                NSBezierPath(
                    roundedRect: CGRect(
                        x: left - pad, y: plot.minY - 3, width: width + pad * 2, height: plot.height + 6),
                    xRadius: min(4, pad * 2), yRadius: min(4, pad * 2)
                ).fill()
            }

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
                SeriesColor.of(band, dark: isDark).setFill()
                // Only the data end is rounded; everything below stays square on the baseline.
                let path = isTop && height > 4 && width >= 8
                    ? roundedTop(rect, radius: 4) : NSBezierPath(rect: rect)
                path.fill()
                y += full
            }

            if period.smartCharge {
                SeriesColor.smart(dark: isDark).setFill()
                NSBezierPath(rect: CGRect(x: left, y: plot.minY - 6, width: width, height: 3)).fill()
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

    private func drawLegend() {
        // Always present for three series, and it carries each band's weekly total so the
        // numbers are readable as text and not only as colour.
        var x: CGFloat = 52
        let y = bounds.height - 20
        for band in bands {
            let total = periods.reduce(0) { $0 + $1.value(band, unit) }
            guard total > 0 else { continue }
            SeriesColor.of(band, dark: isDark).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y + 1, width: 9, height: 9), xRadius: 2, yRadius: 2).fill()
            let text = "\(band.rawValue) \(formatUsage(total, unit, withUnit: true, energyLabel: energyLabel))"
            label(text, at: CGPoint(x: x + 14, y: y - 1), size: 10, color: .secondaryLabelColor)
            x += 14 + text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width + 16
        }
        guard periods.contains(where: \.smartCharge) else { return }
        SeriesColor.smart(dark: isDark).setFill()
        NSBezierPath(rect: CGRect(x: x, y: y + 4, width: 9, height: 3)).fill()
        label("Smart charge", at: CGPoint(x: x + 14, y: y - 1), size: 10, color: .secondaryLabelColor)
    }

    private func drawTooltip(for index: Int, plot: CGRect) {
        let period = periods[index]
        let heading: String
        if granularity == .day {
            heading = period.hasData
                ? "\(formatted(period.start, "EEE d MMM", tz))  ·  \(formatUsage(period.total(unit, bands), unit, withUnit: true, energyLabel: energyLabel))"
                : formatted(period.start, "EEE d MMM", tz)
        } else {
            heading = "\(formatted(period.start, "EEE d MMM HH:mm", tz))–\(formatted(period.end, "HH:mm", tz))"
                + "  ·  \(formatUsage(period.total(unit, bands), unit, withUnit: true, energyLabel: energyLabel))"
        }
        var lines = [TooltipLine(heading)]
        if !period.hasData {
            lines.append(TooltipLine("No data yet — Octopus publishes about two days behind"))
        }
        for band in bands where period.value(band, unit) > 0 {
            var text = "\(band.rawValue): \(formatUsage(period.value(band, unit), unit, withUnit: true, energyLabel: energyLabel))"
            if let price = period.price(band) { text += String(format: " @ %.2fp", price) }
            lines.append(TooltipLine(text, SeriesColor.of(band, dark: isDark)))
        }
        if period.smartCharge {
            lines.append(TooltipLine("Smart charge ran in this period", SeriesColor.smart(dark: isDark)))
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
    periods: [UsagePeriod], unit: UsageUnit, granularity: Granularity, dark: Bool, size: CGSize,
    hover: Int? = nil, placeholder: String? = nil, to path: String
) {
    let view = UsageChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.periods = periods
    view.granularity = granularity
    view.unit = unit
    view.placeholder = placeholder
    view.previewHover(hover)
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
    // Must match the bottom inset in draw(), or the scan lands on the smart-charge markers.
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
