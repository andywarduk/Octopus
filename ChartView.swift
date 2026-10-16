// What both charts are built from: the ChartView base class, the tooltip box, axis scaling, hover
// tinting and the offscreen render the chart demo uses.

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

/// Laid over a hovered bar's own shapes, so the bar itself is marked. Chosen per fill: a dark fill
/// is lightened and a light one darkened, since darkening a near-black band — the carbon chart's
/// "very high" — changes nothing you can see. The bar's colour still reads through it.
func hoverTint(over fill: NSColor) -> NSColor {
    let rgb = fill.usingColorSpace(.sRGB) ?? fill
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return (luminance < 0.35 ? NSColor.white : NSColor.black).withAlphaComponent(0.25)
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

/// Space under the plot for the boundary ticks and the day labels.
let plotBottomInset: CGFloat = 30

// MARK: - Shared tooltip
//
// Both charts draw the same box.

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

/// The window background the charts sit on, which an offscreen render has to paint for itself.
func chartSurface(dark: Bool) -> NSColor { dark ? hexColor("#1a1a19") : hexColor("#fcfcfb") }

/// Draws a chart view offscreen. The surface goes down first: the view draws on a clear background.
@MainActor
func renderOffscreen(_ view: NSView, dark: Bool) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    chartSurface(dark: dark).setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep?, to path: String) {
    try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// What the usage and carbon charts share: hit-testing the pointer against a slot, labels, pixel
/// snapping, the placeholder, the midnight and noon rules and the hover highlight. Each subclass
/// draws its own grid, columns, legend and tooltip.
@MainActor
class ChartView: NSView {
    /// Shown centred when there is nothing to plot, so the plot area is never just blank.
    var placeholder: String? { didSet { needsDisplay = true } }
    var tz: TimeZone = .current { didSet { needsDisplay = true } }
    var hoverIndex: Int?
    var plotRect: CGRect = .zero
    var slotWidth: CGFloat = 0

    /// How many columns there are to hover over. Zero shows the placeholder.
    var slotCount: Int { 0 }

    override var isFlipped: Bool { false }

    /// Device pixels per point: 2 on a Retina display, 1 offscreen where there is no window.
    var pixelScale: CGFloat { window?.backingScaleFactor ?? 1 }

    /// Snaps to the device pixel grid rather than to whole points. Points are two device pixels
    /// on Retina, so rounding to them makes half-hourly bars alternate 1pt and 2pt — a visible
    /// 2:1 difference in thickness. Snapping finer keeps edges crisp and the widths closer.
    func snapToPixel(_ value: CGFloat) -> CGFloat {
        (value * pixelScale).rounded() / pixelScale
    }

    var isDark: Bool {
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
            if slot >= 0 && slot < slotCount { index = slot }
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

    /// Clears the view. With nothing to plot it shows the placeholder instead and returns false.
    func beginDrawing(_ dirtyRect: NSRect) -> Bool {
        NSColor.clear.set()
        dirtyRect.fill()
        guard slotCount > 0 else {
            if let placeholder {
                label(
                    placeholder, at: CGPoint(x: bounds.midX, y: bounds.midY - 6), size: 12,
                    color: .tertiaryLabelColor, align: .centre)
            }
            return false
        }
        return true
    }

    /// The plot area: a gutter for the tick labels on the left, `top` for the legend above, and
    /// `plotBottomInset` for the time axis below.
    func plotArea(top: CGFloat) -> CGRect {
        let left: CGFloat = 52, right: CGFloat = 14
        let bottom = plotBottomInset
        return CGRect(
            x: left, y: bottom, width: max(10, bounds.width - left - right),
            height: max(10, bounds.height - top - bottom))
    }

    enum Align {
        case left, right, centre
    }

    func label(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, align: Align = .left) {
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

    /// Vertical rules at each slot boundary that falls on midnight or noon: strong at midnight,
    /// faint at noon. Drawn before the columns so it stays behind the data.
    func drawTimeGrid(plot: CGRect, starts: [Date]) {
        let cal = calendar(tz)
        for (index, start) in starts.enumerated() where index > 0 {
            let parts = cal.dateComponents([.hour, .minute], from: start)
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

    /// The hovered column's background. Drawn before any bar, so both neighbours cover its
    /// padding: drawn inside the loop, the bar to the left was already painted and the padding
    /// tinted its edge — a faint line on the left of the highlighted bar and none on the right.
    func drawHoverHighlight(left: CGFloat, width: CGFloat, plot: CGRect) {
        // Pad by a fraction of the bar, not a fixed amount: 3px either side of a 1.6px
        // half-hourly bar makes the highlight wider than the thing it marks.
        let pad = min(3, max(0.5, width / 3))
        NSColor.secondaryLabelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(
            roundedRect: CGRect(x: left - pad, y: plot.minY - 3, width: width + pad * 2, height: plot.height + 6),
            xRadius: min(4, pad * 2), yRadius: min(4, pad * 2)
        ).fill()
    }
}
