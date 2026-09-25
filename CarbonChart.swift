// The carbon intensity chart: one series of half-hourly forecasts, coloured by index band.
//
// Unlike the usage chart this is a single series, so there are no categorical slots to assign.
// The index is an ordinal scale — very low through very high — which calls for a sequential ramp
// in one hue rather than a green-to-red rainbow. Colour never carries the meaning alone: the
// legend names all five bands, the tooltip prints the word, and the bar's height is the number.

import Cocoa

enum CarbonColor {
    // One hue, stepped by lightness. Light mode runs pale to deep, so more ink means more carbon.
    // Dark mode runs dim to bright rather than flipping the light steps, because on a dark
    // surface the deep end would disappear into the background and "more" has to mean brighter.
    // Checked numerically: lightness is monotonic in both, adjacent steps differ by about 1.5:1,
    // and the top bands clear 7:1 against their surface.
    static let light: [CarbonIndex: NSColor] = [
        .veryLow: hexColor("#b9ade0"), .low: hexColor("#9a85d2"), .moderate: hexColor("#7b5fc0"),
        .high: hexColor("#5d3fa2"), .veryHigh: hexColor("#412a73"),
    ]
    static let dark: [CarbonIndex: NSColor] = [
        .veryLow: hexColor("#4b3a7d"), .low: hexColor("#6a53a8"), .moderate: hexColor("#8a70cb"),
        .high: hexColor("#a98fe0"), .veryHigh: hexColor("#c9b4f2"),
    ]

    static func of(_ index: CarbonIndex, dark isDark: Bool) -> NSColor {
        (isDark ? dark : light)[index] ?? .systemGray
    }
}

/// The generation mix's colours: the eight validated categorical slots in their documented order,
/// assigned to fuels in stack order, plus neutral grey for the unknown residual at the bottom.
///
/// The slots clear their colourblind gates on the *adjacent* pairlist, and in a stack "adjacent"
/// means next to each other in `GridFuel.allCases` — so the assignment below must stay in step
/// with that order. Validated as a nine-colour sequence: worst adjacent CVD ΔE 9.1 light and 8.4
/// dark, both above the 8 target. Grey fails the chroma floor deliberately, exactly as the usage
/// chart's standing charge does: it marks the residual, which is not a fuel.
enum FuelColor {
    static let light: [GridFuel: NSColor] = [
        .other: hexColor("#8a8a84"), .gas: hexColor("#2a78d6"), .coal: hexColor("#eb6834"),
        .imports: hexColor("#1baf7a"), .biomass: hexColor("#eda100"), .nuclear: hexColor("#e87ba4"),
        .hydro: hexColor("#008300"), .wind: hexColor("#4a3aa7"), .solar: hexColor("#e34948"),
    ]
    static let dark: [GridFuel: NSColor] = [
        .other: hexColor("#9a9a92"), .gas: hexColor("#3987e5"), .coal: hexColor("#d95926"),
        .imports: hexColor("#199e70"), .biomass: hexColor("#c98500"), .nuclear: hexColor("#d55181"),
        .hydro: hexColor("#008300"), .wind: hexColor("#9085e9"), .solar: hexColor("#e66767"),
    ]

    static func of(_ fuel: GridFuel, dark isDark: Bool) -> NSColor {
        (isDark ? dark : light)[fuel] ?? .systemGray
    }
}

/// What the chart is plotting. The mix is only offered when the source supplies one.
enum CarbonMode: String, CaseIterable {
    case intensity, mix

    var title: String { self == .intensity ? "Intensity" : "Fuel Mix" }
}

func formatGrams(_ value: Double, short: Bool = false) -> String {
    short ? String(format: "%g", value) : String(format: "%.0f gCO₂/kWh", value)
}

/// The line between "green" and "not so green" that Octopus draws on its own site, and a common
/// convention elsewhere. A published reference rather than a number invented here, which is why
/// it earns a rule on the chart when a spike threshold would not.
let greenThresholdGrams: Double = 100

/// Demand runs to tens of thousands of megawatts, so the axis reads in gigawatts. The tooltip
/// keeps a decimal place; the axis doesn't need one.
func formatPower(_ megawatts: Double, short: Bool = false) -> String {
    short ? String(format: "%g", (megawatts / 1000).rounded()) : String(format: "%.1f GW", megawatts / 1000)
}

@MainActor
final class CarbonChartView: NSView {
    var readings: [CarbonReading] = [] { didSet { needsDisplay = true } }
    var mode: CarbonMode = .intensity { didSet { needsDisplay = true } }
    var placeholder: String? { didSet { needsDisplay = true } }
    var tz: TimeZone = .current { didSet { needsDisplay = true } }
    /// Drawn as a "now" rule. Held rather than read from the clock so the offscreen renderer can
    /// place it deterministically.
    var now: Date = Date() { didSet { needsDisplay = true } }
    private var hoverIndex: Int?
    private var plotRect: CGRect = .zero
    private var slotWidth: CGFloat = 0

    override var isFlipped: Bool { false }

    private var pixelScale: CGFloat { window?.backingScaleFactor ?? 1 }

    /// Same reasoning as the usage chart: snapping to whole points makes neighbouring bars
    /// alternate 1pt and 2pt on a Retina display.
    private func snapToPixel(_ value: CGFloat) -> CGFloat {
        (value * pixelScale).rounded() / pixelScale
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Shared with the footer, so the two can never describe different charts.
    private var scaledToDemand: Bool { carbonScaledToDemand(readings) }

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
        var index: Int?
        if slotWidth > 0, plotRect.insetBy(dx: 0, dy: -8).contains(point) {
            let slot = Int((point.x - plotRect.minX) / slotWidth)
            if slot >= 0 && slot < readings.count { index = slot }
        }
        if index != hoverIndex {
            hoverIndex = index
            needsDisplay = true
        }
    }

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
        guard !readings.isEmpty else {
            if let placeholder {
                label(
                    placeholder, at: CGPoint(x: bounds.midX, y: bounds.midY - 6), size: 12,
                    color: .tertiaryLabelColor, align: .centre)
            }
            return
        }

        // The legend wraps to two rows at narrow widths, so the top inset allows for both.
        let left: CGFloat = 52, right: CGFloat = 14, top: CGFloat = 58
        let bottom = plotBottomInset
        let plot = CGRect(
            x: left, y: bottom, width: max(10, bounds.width - left - right),
            height: max(10, bounds.height - top - bottom))
        // In the mix view a bar stands at that half hour's GB demand, so the shape shows when the
        // country is actually drawing power. Without demand it falls back to a flat 100%: a share
        // scaled to the tallest column would make an always-100% stack look like it varied.
        let (axisMax, axisStep): (Double, Double)
        switch mode {
        case .intensity: (axisMax, axisStep) = axisScale(readings.map(\.grams).max() ?? 1)
        case .mix where scaledToDemand:
            (axisMax, axisStep) = axisScale(readings.compactMap(\.demandMW).max() ?? 1)
        case .mix: (axisMax, axisStep) = (100, 25)
        }

        slotWidth = plot.width / CGFloat(readings.count)
        drawGrid(plot: plot, axisMax: axisMax, step: axisStep)
        drawTimeGrid(plot: plot)
        drawColumns(plot: plot, axisMax: axisMax)
        drawGreenLine(plot: plot, axisMax: axisMax)
        drawNowRule(plot: plot)
        drawTimeAxis(plot: plot)
        drawLegend()
        plotRect = plot
        if let hoverIndex, hoverIndex < readings.count { drawTooltip(for: hoverIndex, plot: plot) }
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
            let tick: String
            switch mode {
            case .intensity: tick = formatGrams(value, short: true)
            case .mix where scaledToDemand: tick = formatPower(value, short: true)
            case .mix: tick = String(format: "%g", value)
            }
            label(
                tick, at: CGPoint(x: plot.minX - 8, y: y - 6), size: 10, color: .tertiaryLabelColor,
                align: .right)
        }
        // The ticks are bare numbers, so the axis has to say what they are. Once, above the
        // scale, rather than suffixed onto every tick. Left-aligned at the edge: the caption is
        // wider than the tick gutter, so right-aligning it to the axis clips the leading "g".
        // Top right, not top left: the "now" rule's label sits at the left of a forecast and the
        // two collide there.
        let caption: String
        switch mode {
        case .intensity: caption = "gCO₂/kWh"
        case .mix where scaledToDemand: caption = "GB demand, GW"
        case .mix: caption = "% of generation"
        }
        label(
            caption, at: CGPoint(x: plot.maxX, y: plot.maxY + 6), size: 10,
            color: .tertiaryLabelColor, align: .right)
    }

    /// Midnight solid, noon dashed and fainter — the same treatment as the half-hourly usage
    /// chart, so the two windows read the same way.
    private func drawTimeGrid(plot: CGRect) {
        let cal = calendar(tz)
        for (index, reading) in readings.enumerated() where index > 0 {
            let parts = cal.dateComponents([.hour, .minute], from: reading.start)
            guard parts.minute == 0, parts.hour == 0 || parts.hour == 12 else { continue }
            let isMidnight = parts.hour == 0
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
        // Half-hourly bars always meet: the strip reads as one shape at any width. A gap once the
        // bars grew wide enough striped the stack and read as a cap on how wide a bar could get.
        func column(_ index: Int) -> (edge: CGFloat, width: CGFloat) {
            let edge = snapToPixel(plot.minX + slotWidth * CGFloat(index))
            let nextEdge = snapToPixel(plot.minX + slotWidth * CGFloat(index + 1))
            return (edge, max(1, nextEdge - edge))
        }

        // Before any bar, so both neighbours cover the padding; see the usage chart.
        if let hoverIndex, hoverIndex < readings.count {
            let (edge, width) = column(hoverIndex)
            let pad = min(3, max(0.5, width / 3))
            NSColor.secondaryLabelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(
                roundedRect: CGRect(
                    x: edge - pad, y: plot.minY - 3, width: width + pad * 2, height: plot.height + 6),
                xRadius: min(4, pad * 2), yRadius: min(4, pad * 2)
            ).fill()
        }

        for (index, reading) in readings.enumerated() {
            let (edge, width) = column(index)

            switch mode {
            case .intensity:
                let height = max(1, CGFloat(reading.grams / axisMax) * plot.height)
                CarbonColor.of(reading.index, dark: isDark).setFill()
                let bar = NSBezierPath(rect: CGRect(x: edge, y: plot.minY, width: width, height: height))
                bar.fill()
                if hoverIndex == index {
                    // The bar itself is marked, as in the usage chart.
                    hoverTint(over: CarbonColor.of(reading.index, dark: isDark)).setFill()
                    bar.fill()
                }
            case .mix:
                // Normalised to the column's own total rather than trusted to be exactly 100.
                // The shares are rounded to a decimal place at source, so they can total 100.1 —
                // enough to draw a sliver above the axis, which on a share chart reads as a bug.
                let total = reading.mix.reduce(0) { $0 + $1.percent }
                guard total > 0 else { continue }
                // The stack's full height: demand when known, otherwise the whole axis.
                let barHeight: CGFloat
                if scaledToDemand {
                    guard let demand = reading.demandMW else {
                        // No demand for this half hour. A bare baseline dash reads as damage in a
                        // chart this dense, so the whole column is faintly banded instead.
                        NSColor.tertiaryLabelColor.withAlphaComponent(0.12).setFill()
                        NSBezierPath(rect: CGRect(x: edge, y: plot.minY, width: width, height: plot.height))
                            .fill()
                        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setFill()
                        NSBezierPath(rect: CGRect(x: edge, y: plot.minY, width: width, height: 2)).fill()
                        continue
                    }
                    barHeight = CGFloat(demand / axisMax) * plot.height
                } else {
                    barHeight = plot.height
                }
                // Stacked in GridFuel order, which is what the palette was validated against.
                var y = plot.minY
                for share in reading.mix {
                    let full = CGFloat(share.percent / total) * barHeight
                    FuelColor.of(share.fuel, dark: isDark).setFill()
                    let segment = NSBezierPath(rect: CGRect(x: edge, y: y, width: width, height: max(0.5, full)))
                    segment.fill()
                    if hoverIndex == index {
                        hoverTint(over: FuelColor.of(share.fuel, dark: isDark)).setFill()
                        segment.fill()
                    }
                    y += full
                }
            }
        }
    }

    /// The green threshold, drawn over the columns rather than behind them: at half-hourly width
    /// the bars are a solid wall and a rule behind them would be invisible for most of the chart.
    /// Intensity only — it means nothing against a demand or percentage axis.
    private func drawGreenLine(plot: CGRect, axisMax: Double) {
        guard mode == .intensity, axisMax > greenThresholdGrams else { return }
        let y = (plot.minY + plot.height * CGFloat(greenThresholdGrams / axisMax)).rounded() + 0.5
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: plot.minX, y: y))
        line.line(to: CGPoint(x: plot.maxX, y: y))
        line.lineWidth = 1
        line.setLineDash([5, 4], count: 2, phase: 0)
        line.stroke()
        // Sits just above its own line, right-aligned, where no column label can reach it.
        label(
            "green below \(Int(greenThresholdGrams))", at: CGPoint(x: plot.maxX - 2, y: y + 3),
            size: 9, color: .secondaryLabelColor, align: .right)
    }

    /// A forecast is only meaningful relative to now, so say where now is.
    private func drawNowRule(plot: CGRect) {
        guard let first = readings.first, let last = readings.last,
            now >= first.start, now <= last.end
        else { return }
        let span = last.end.timeIntervalSince(first.start)
        guard span > 0 else { return }
        let x = plot.minX + plot.width * CGFloat(now.timeIntervalSince(first.start) / span)
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: x.rounded() + 0.5, y: plot.minY))
        line.line(to: CGPoint(x: x.rounded() + 0.5, y: plot.maxY))
        line.lineWidth = 1
        line.setLineDash([2, 2], count: 2, phase: 0)
        line.stroke()
        label(
            "now", at: CGPoint(x: x, y: plot.maxY + 2), size: 9, color: .secondaryLabelColor,
            align: .centre)
    }

    /// One day name per day, centred on its run, plus the hour at each midnight boundary.
    private func drawTimeAxis(plot: CGRect) {
        let cal = calendar(tz)
        var runStart = 0
        for index in 0...readings.count {
            let isBoundary = index == readings.count
                || !cal.isDate(readings[index].start, inSameDayAs: readings[runStart].start)
            guard isBoundary else { continue }
            let from = plot.minX + slotWidth * CGFloat(runStart)
            let to = plot.minX + slotWidth * CGFloat(index)
            if to - from > 30 {
                label(
                    formatted(readings[runStart].start, "EEE d MMM", tz),
                    at: CGPoint(x: (from + to) / 2, y: plot.minY - 20), size: 10,
                    color: .secondaryLabelColor, align: .centre)
            }
            runStart = index
        }
    }

    private func drawLegend() {
        // Always present, and it wraps rather than truncating: with nine fuels the legend is the
        // only thing carrying identity, since a one-pixel stack segment can't be labelled.
        var x: CGFloat = 52
        var y = bounds.height - 20
        let font = NSFont.systemFont(ofSize: 10)

        func entry(_ text: String, _ color: NSColor) {
            let width = 14 + text.size(withAttributes: [.font: font]).width + 14
            if x + width > bounds.width - 8 {
                x = 52
                y -= 15
            }
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y + 1, width: 9, height: 9), xRadius: 2, yRadius: 2)
                .fill()
            label(text, at: CGPoint(x: x + 14, y: y - 1), size: 10, color: .secondaryLabelColor)
            x += width
        }

        switch mode {
        case .intensity:
            // All five bands, even those the window doesn't reach: the scale is the point.
            for index in CarbonIndex.allCases { entry(index.title, CarbonColor.of(index, dark: isDark)) }
        case .mix:
            // Only fuels that actually appear, with their mean share — nine entries of which
            // several are flat zero would crowd out the ones that matter.
            let means = averageMix(readings)
            for fuel in GridFuel.allCases {
                guard let mean = means[fuel] else { continue }
                // Below half a percent it would print as "0%", which says nothing and crowds out
                // the fuels that matter.
                guard mean >= 0.5 else { continue }
                entry(String(format: "%@ %.0f%%", fuel.title, mean), FuelColor.of(fuel, dark: isDark))
            }
        }
    }

    private func drawTooltip(for index: Int, plot: CGRect) {
        let reading = readings[index]
        var lines = [
            TooltipLine(
                "\(formatted(reading.start, "EEE d MMM HH:mm", tz))–\(formatted(reading.end, "HH:mm", tz))"),
            // The band's swatch in both views. In the fuel-mix view no bar carries that colour, but
            // it still names the band at a glance, the same colour it has in the intensity view.
            TooltipLine(
                "\(formatGrams(reading.grams))  ·  \(reading.index.title)",
                CarbonColor.of(reading.index, dark: isDark)),
        ]
        if let demand = reading.demandMW {
            // Settled outturn behind now, the day-ahead forecast ahead of it: the same figure means
            // different things, and a prediction must not read as a measurement.
            lines.append(TooltipLine(
                reading.demandIsForecast
                    ? "GB demand \(formatPower(demand)) (forecast)"
                    : "GB demand \(formatPower(demand))"))
        } else if mode == .mix, scaledToDemand {
            // Blaming the forecast horizon for the half hour running right now is simply wrong.
            lines.append(
                TooltipLine(
                    demandGap(reading, now: now) == .stillRunning
                        ? "GB demand is published when this half hour ends"
                        : "GB demand not forecast this far ahead"))
        }
        // The mix is what makes a number mean something; Octopus doesn't supply it. Largest share
        // first here, unlike the stack — reading a tooltip, the biggest contributor is the point.
        let ranked = reading.mix.sorted { $0.percent > $1.percent }
        let total = reading.mix.reduce(0) { $0 + $1.percent }
        // Every fuel in both views: the intensity view used to stop at four, which hid what made up
        // the rest of the number.
        for share in ranked {
            var text = String(format: "%@ %.1f%%", share.fuel.title, share.percent)
            // Megawatts per fuel only where the split is the national one. Against a regional
            // share it would be a number that does not exist.
            if let demand = reading.demandMW, reading.mixIsNational, total > 0 {
                text += "  ·  \(formatPower(demand * share.percent / total))"
            }
            lines.append(TooltipLine(text, FuelColor.of(share.fuel, dark: isDark)))
        }
        if reading.mix.isEmpty {
            lines.append(TooltipLine("Generation mix not reported by this source"))
        }

        drawTooltipBox(
            lines, anchorX: plot.minX + slotWidth * (CGFloat(index) + 0.5), slotWidth: slotWidth,
            plot: plot, in: bounds)
    }
}

// MARK: - Offscreen render, for eyeballing the layout without launching the app

@MainActor
func renderCarbonChart(
    readings: [CarbonReading], now: Date, tz: TimeZone, dark: Bool, size: CGSize,
    mode: CarbonMode = .intensity, hover: Int? = nil, placeholder: String? = nil, to path: String
) {
    let view = CarbonChartView(frame: CGRect(origin: .zero, size: size))
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.tz = tz
    view.readings = readings
    view.mode = mode
    view.now = now
    view.placeholder = placeholder
    view.previewHover(hover)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    (dark ? hexColor("#1a1a19") : hexColor("#fcfcfb")).setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// A seeded two-day forecast, so the demo images are identical run to run. Shaped like a real
/// day: a dirty evening peak, a cleaner small-hours trough, and a windy second day.
func sampleCarbonForecast(from start: Date) -> [CarbonReading] {
    var generator = SeededGenerator(seed: 20_260_922)
    return (0..<96).map { slot in
        let hour = Double(slot) / 2
        // Two cycles over 48 hours, with the second day cleaner, plus a little noise.
        let daily = cos((hour - 18) / 24 * 2 * .pi)
        let trend = hour < 24 ? 1.0 : 0.62
        let noise = Double(generator.next() % 24) - 12
        let grams = max(40, (200 + 90 * daily) * trend + noise)
        let index: CarbonIndex
        switch grams {
        case ..<100: index = .veryLow
        case ..<150: index = .low
        case ..<200: index = .moderate
        case ..<250: index = .high
        default: index = .veryHigh
        }
        // A plausible mix: the dirtier the hour, the more of it is gas, and what gas gives up
        // goes to wind. Solar only appears in daylight. Kept in GridFuel order, like real data.
        let gasShare = min(62, max(16, grams / 4))
        let hour24 = hour.truncatingRemainder(dividingBy: 24)
        let solarShare = hour24 > 7 && hour24 < 19 ? (8 * sin((hour24 - 7) / 12 * .pi)) : 0
        // Wind takes up whatever the others leave, so the column totals exactly 100 like the
        // real thing. The fixed shares below add to 26.6, and gas is capped so this stays above
        // its floor even at the sunniest, gassiest half hour.
        let windShare = max(2, 73.4 - gasShare - solarShare)
        let shares: [(GridFuel, Double)] = [
            (.gas, gasShare), (.coal, 0.2), (.imports, 9), (.biomass, 4.8),
            (.nuclear, 12), (.hydro, 0.6), (.wind, windShare), (.solar, solarShare),
        ]
        let mix = shares
            .filter { $0.1 > 0 }
            .map { FuelShare(fuel: $0.0, percent: ($0.1 * 10).rounded() / 10) }
        // GB demand: an overnight trough near 20 GW and an early-evening peak near 34 GW. The
        // last eight hours are left nil, standing in for the edge of the day-ahead forecast.
        let demand = 27_000 - 7_000 * cos((hour24 - 18) / 24 * 2 * .pi) + Double(generator.next() % 600)
        let from = start.addingTimeInterval(Double(slot) * 1800)
        let reading = CarbonReading(
            start: from, end: from.addingTimeInterval(1800), grams: (grams).rounded(),
            index: index, mix: mix,
            // Slot 6 is the half hour in progress, covered by neither the settled outturn nor
            // the day-ahead forecast; past slot 80 is the far end of the forecast horizon. Both
            // gaps are real shapes the live data takes, so the demo renders both.
            demandMW: (slot == 6 || slot >= 80) ? nil : demand.rounded(),
            // Slot 6 is now: everything after it is the day-ahead forecast.
            demandIsForecast: slot > 6,
            mixIsNational: slot < 48)
        return reading
    }
}
