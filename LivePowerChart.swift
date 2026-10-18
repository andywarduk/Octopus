// The live power chart: one series, watts over time, drawn as a line over a faint wash.
//
// Unlike the other two charts this is a trace rather than columns: 360 ten-second readings are one
// continuous quantity, not a set of periods to compare. A single series needs no legend — the
// window's title names it — and takes the palette's first slot.

import Cocoa

enum LivePowerColor {
    /// The first categorical slot, validated in both modes.
    static func of(dark: Bool) -> NSColor { dark ? hexColor("#3987e5") : hexColor("#2a78d6") }
}

@MainActor
final class LivePowerChartView: ChartView {
    var series: LivePowerSeries? { didSet { needsDisplay = true } }

    override var slotCount: Int { series.map { $0.isEmpty ? 0 : $0.watts.count } ?? 0 }

    override func draw(_ dirtyRect: NSRect) {
        guard beginDrawing(dirtyRect), let series else { return }
        // Room right of the plot for the newest reading's label, where no part of the line can be.
        // Inside the plot, a spike just before the newest reading — the kettle, say — ran straight
        // through it. A fixed width for the widest figure, so the plot doesn't shift each refresh.
        var plot = plotArea(top: 24)
        plot.size.width -= endLabelWidth
        slotWidth = plot.width / CGFloat(series.watts.count)
        // Never scaled below 100 W, so a house drawing next to nothing doesn't have its noise
        // magnified into a mountain range.
        let (axisMax, step) = axisScale(max(series.peak?.watts ?? 0, 100))

        drawGrid(plot: plot, axisMax: axisMax, step: step)
        drawTimeGrid(plot: plot, starts: series.watts.indices.map(series.slotStart))
        drawTimeAxis(plot: plot, series: series)
        if let hoverIndex, hoverIndex < series.watts.count { drawCrosshair(at: hoverIndex, plot: plot) }
        drawTrace(plot: plot, series: series, axisMax: axisMax)
        if let latest = series.latest { drawEndLabel(latest, plot: plot, axisMax: axisMax) }
        plotRect = plot
        if let hoverIndex, hoverIndex < series.watts.count {
            if let watts = series.watts[hoverIndex] {
                drawDot(at: point(hoverIndex, watts, plot: plot, axisMax: axisMax))
            }
            drawTooltip(for: hoverIndex, series: series, plot: plot)
        }
    }

    /// The centre of a slot, at its reading. A negative figure — export, if it ever arrives that
    /// way — sits on the baseline rather than below the plot.
    private func point(_ index: Int, _ watts: Double, plot: CGRect, axisMax: Double) -> CGPoint {
        CGPoint(
            x: plot.minX + slotWidth * (CGFloat(index) + 0.5),
            y: plot.minY + plot.height * CGFloat(max(0, watts) / axisMax))
    }

    private func drawGrid(plot: CGRect, axisMax: Double, step: Double) {
        // Kilowatts once the axis reaches two of them: "7000" in a tick gutter reads as a code.
        let kilowatts = axisMax >= 2000
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let lines = max(1, Int((axisMax / step).rounded()))
        for index in 0...lines {
            let value = step * Double(index)
            let y = plot.minY + plot.height * CGFloat(value / axisMax)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y.rounded() + 0.5))
            line.line(to: CGPoint(x: plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            label(
                String(format: "%g", kilowatts ? value / 1000 : value), at: CGPoint(x: plot.minX - 8, y: y - 6),
                size: 10, color: .tertiaryLabelColor, align: .right)
        }
        // Once, above the scale, as the carbon chart does, rather than suffixed onto every tick.
        label(
            kilowatts ? "kW" : "W", at: CGPoint(x: plot.maxX, y: plot.maxY + 6), size: 10,
            color: .tertiaryLabelColor, align: .right)
    }

    /// Clock times at round steps under the axis, with the day's name in place of midnight.
    private func drawTimeAxis(plot: CGRect, series: LivePowerSeries) {
        let stepMinutes: Int
        switch series.range {
        case .hour: stepMinutes = 10
        case .sixHours: stepMinutes = 60
        case .day: stepMinutes = 180
        }
        let cal = calendar(tz)
        NSColor.separatorColor.setStroke()
        for index in 0...series.watts.count {
            let at = series.slotStart(index)
            let parts = cal.dateComponents([.hour, .minute, .second], from: at)
            let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            guard parts.second == 0, minuteOfDay % stepMinutes == 0 else { continue }
            let x = plot.minX + slotWidth * CGFloat(index)
            // Half a label's width from either edge, or it is clipped.
            guard x > plot.minX + 14, x < bounds.width - 16 else { continue }
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: x.rounded() + 0.5, y: plot.minY))
            tick.line(to: CGPoint(x: x.rounded() + 0.5, y: plot.minY - 4))
            tick.lineWidth = 1
            tick.stroke()
            label(
                minuteOfDay == 0 ? formatted(at, "EEE", tz) : formatted(at, "HH:mm", tz),
                at: CGPoint(x: x, y: plot.minY - 18), size: 10, color: .secondaryLabelColor, align: .centre)
        }
    }

    /// A 2pt line over a wash of the same hue, broken where readings are missing. Runs shorter
    /// than `bridgedSlots` are drawn across, since an odd ten-second row goes missing all the time
    /// and is no more a gap than the space between two readings.
    private func drawTrace(plot: CGRect, series: LivePowerSeries, axisMax: Double) {
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        var missing = 0
        for (index, watts) in series.watts.enumerated() {
            guard let watts else {
                missing += 1
                continue
            }
            if missing > series.range.bridgedSlots, !run.isEmpty {
                runs.append(run)
                run = []
            }
            missing = 0
            run.append(point(index, watts, plot: plot, axisMax: axisMax))
        }
        if !run.isEmpty { runs.append(run) }

        let color = LivePowerColor.of(dark: isDark)
        for points in runs {
            guard let first = points.first, let last = points.last else { continue }
            if points.count == 1 {
                // Nothing either side to join: a dot the line's width, so it still shows.
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)).fill()
                continue
            }
            let wash = NSBezierPath()
            wash.move(to: CGPoint(x: first.x, y: plot.minY))
            for point in points { wash.line(to: point) }
            wash.line(to: CGPoint(x: last.x, y: plot.minY))
            wash.close()
            color.withAlphaComponent(0.1).setFill()
            wash.fill()

            let line = NSBezierPath()
            line.move(to: first)
            for point in points.dropFirst() { line.line(to: point) }
            line.lineWidth = 2
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }
    }

    /// A marker with a ring of the surface around it, so it reads where it crosses the line.
    private func drawDot(at point: CGPoint) {
        chartSurface(dark: isDark).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
        LivePowerColor.of(dark: isDark).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
    }

    private let endLabelFont = NSFont.systemFont(ofSize: 11)

    private var endLabelWidth: CGFloat {
        ceil("88.8 kW".size(withAttributes: [.font: endLabelFont]).width) + 10
    }

    /// The newest reading, marked and labelled at the end of the line: the one figure the window
    /// is opened for. The dot has no surface ring, unlike the hover marker — it ends its own line
    /// rather than crossing it, and at five-minute spacing the ring hid the whole last segment.
    private func drawEndLabel(_ latest: (index: Int, watts: Double), plot: CGRect, axisMax: Double) {
        let end = point(latest.index, latest.watts, plot: plot, axisMax: axisMax)
        LivePowerColor.of(dark: isDark).setFill()
        NSBezierPath(ovalIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)).fill()
        label(
            powerText(latest.watts), at: CGPoint(x: plot.maxX + 8, y: end.y - 7), size: 11,
            color: .labelColor)
    }

    /// The pointer finds the time; the reader never has to land on a two-point line.
    private func drawCrosshair(at index: Int, plot: CGRect) {
        let x = (plot.minX + slotWidth * (CGFloat(index) + 0.5)).rounded() + 0.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.line(to: CGPoint(x: x, y: plot.maxY))
        line.lineWidth = 1
        line.stroke()
    }

    private func drawTooltip(for index: Int, series: LivePowerSeries, plot: CGRect) {
        let from = series.slotStart(index)
        var lines: [TooltipLine]
        if series.range.plotsDemand {
            lines = [TooltipLine(formatted(from, "HH:mm:ss", tz))]
            lines.append(TooltipLine(series.watts[index].map(powerText) ?? "No reading"))
        } else {
            let to = series.slotStart(index + 1)
            let day = series.range == .day ? "EEE " : ""
            lines = [TooltipLine("\(formatted(from, day + "HH:mm", tz))–\(formatted(to, "HH:mm", tz))")]
            if let watts = series.watts[index] {
                // The average is what the bucket's energy works out to; say so, and give the energy.
                let wh = watts * series.range.interval / 3600
                lines.append(TooltipLine("\(powerText(watts)) average  ·  \(String(format: "%.0f", wh)) Wh"))
            } else {
                lines.append(TooltipLine("No reading"))
            }
        }
        drawTooltipBox(
            lines, anchorX: plot.minX + slotWidth * (CGFloat(index) + 0.5), slotWidth: slotWidth,
            plot: plot, in: bounds)
    }
}

// MARK: - Offscreen render, for eyeballing the layout without launching the app

@MainActor
func renderLivePowerChart(
    series: LivePowerSeries?, dark: Bool, size: CGSize, hover: Int? = nil, placeholder: String? = nil,
    to path: String
) {
    let view = LivePowerChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.tz = londonTimeZone
    view.series = series
    view.placeholder = placeholder
    view.previewHover(hover)
    writePNG(renderOffscreen(view, dark: dark), to: path)
}

/// A seeded house, so the demo images are identical run to run, built as telemetry rows and laid
/// out by `liveSeries` like the real thing. A base load with a fridge cycling, a kettle, cooking in
/// the evening and the car charging overnight — plus a stray missing row and a real gap, the two
/// shapes missing data takes.
func sampleLivePower(range: LivePowerRange, now: Date) -> LivePowerSeries {
    var generator = SeededGenerator(seed: 20_261_012)
    let cal = calendar(londonTimeZone)
    let interval = range.interval
    let first = now.addingTimeInterval(-range.span - interval)
    var rows: [[String: Any]] = []
    var at = Date(timeIntervalSince1970: (first.timeIntervalSince1970 / interval).rounded(.down) * interval)
    while at <= now {
        defer { at = at.addingTimeInterval(interval) }
        let minutesAgo = Int(now.timeIntervalSince(at) / 60)
        // The real gap: two minutes of nothing in the hour, a quarter of an hour in the longer views.
        if range == .hour ? (24...25).contains(minutesAgo) : (300...314).contains(minutesAgo) { continue }
        // The stray missing ten-second row.
        if range == .hour, generator.next() % 40 == 0 { continue }
        let parts = cal.dateComponents([.hour, .minute], from: at)
        let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var watts = 240 + Double(generator.next() % 30)
        // The fridge: twelve minutes in every thirty.
        if minuteOfDay % 30 < 12 { watts += 85 }
        // The kettle, three minutes of it, twenty minutes back.
        if (18...20).contains(minutesAgo) { watts += 2900 }
        // Cooking, 17:30 to 18:30.
        if (17 * 60 + 30..<18 * 60 + 30).contains(minuteOfDay) { watts += 1600 + Double(generator.next() % 400) }
        // The car, 23:30 to 03:00 at 7.2 kW.
        if minuteOfDay >= 23 * 60 + 30 || minuteOfDay < 3 * 60 { watts += 7200 }
        rows.append([
            "readAt": iso8601(at), "demand": String(format: "%.1f", watts),
            "consumptionDelta": String(format: "%.4f", watts * interval / 3600),
        ])
    }
    return liveSeries(rows: rows, range: range, now: now)
}
