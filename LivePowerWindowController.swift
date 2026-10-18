// One live power window. There is an instance per meter with a Home Mini, opened from its line in
// the menu, so two houses each get their own window, range and refresh.

import Cocoa

@MainActor
final class LivePowerWindowController: NSObject {
    let meter: LiveMeter
    /// How far to step this window, so several open at once don't stack exactly.
    private let cascade: Int
    private let apiKey: () -> String?

    private var window: NSWindow?
    private var chart: LivePowerChartView?
    private var statusLine: StatusLine?
    private var footer: NSTextField?

    private var range: LivePowerRange = .hour
    /// Keyed by range, so switching back shows what was there at once while it is asked for again.
    private var cache: [LivePowerRange: LivePowerSeries] = [:]
    private var loading = false
    /// Bumped when the window closes for good, so a fetch in flight is neither shown nor cached.
    private var generation = 0

    /// Asks again while the window is up, at the range's own pace, and stops itself once it is
    /// closed. Requests are spent only while someone is looking.
    private var refresher: Timer?

    private let tz = londonTimeZone

    init(meter: LiveMeter, cascade: Int, apiKey: @escaping () -> String?) {
        self.meter = meter
        self.cascade = cascade
        self.apiKey = apiKey
    }

    /// Closes the window for good: the key it belonged to has gone.
    func close() {
        generation += 1
        stopRefreshing()
        window?.close()
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        showRange()
        startRefreshing()
    }

    // MARK: - Layout

    private func build() {
        let ranges = NSSegmentedControl(
            labels: LivePowerRange.allCases.map(\.title), trackingMode: .selectOne, target: self,
            action: #selector(rangeChanged(_:)))
        ranges.selectedSegment = range.rawValue

        let controls = NSStackView(views: [ranges])
        let status = StatusLine()
        let chartView = LivePowerChartView()
        chartView.tz = tz
        let footerField = makeFooterField()
        let container = chartWindowContent(
            controls: controls, status: status.field, chart: chartView, footer: footerField)

        let newWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // Named for its address, as the usage windows are, since two can be open side by side.
        newWindow.title = meter.property.isEmpty ? "Live Power" : "Live Power · \(meter.property)"
        newWindow.contentView = container
        newWindow.isReleasedWhenClosed = false
        newWindow.setContentSize(CGSize(width: 620, height: 340))
        newWindow.contentMinSize = CGSize(width: 460, height: 280)
        // Up and to the left of centre, where neither the usage windows nor the carbon window go.
        newWindow.center()
        var origin = newWindow.frame.origin
        origin.x -= CGFloat(56 + 28 * cascade)
        origin.y += CGFloat(56 - 28 * cascade)
        newWindow.setFrameOrigin(origin)

        window = newWindow
        chart = chartView
        statusLine = status
        footer = footerField
    }

    // MARK: - Controls

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        guard let picked = LivePowerRange(rawValue: sender.selectedSegment), picked != range else { return }
        range = picked
        // The pace belongs to the range: once a minute for the hour, every five for the others.
        stopRefreshing()
        startRefreshing()
        showRange()
    }

    /// Whatever is in hand for the range at once, then a fetch if it is due. A refresh keeps the
    /// chart up until the new one lands rather than flashing "Loading…" every minute.
    private func showRange() {
        if let cached = cache[range] {
            apply(cached)
            if cached.isStale(now: Date()) { load() }
        } else {
            chart?.series = nil
            chart?.placeholder = "Loading…"
            footer?.stringValue = ""
            load()
        }
    }

    private func startRefreshing() {
        guard refresher == nil else { return }
        let timer = Timer(timeInterval: range.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refresher = timer
    }

    private func stopRefreshing() {
        refresher?.invalidate()
        refresher = nil
    }

    private func tick() {
        guard window?.isVisible == true else {
            stopRefreshing()
            return
        }
        load()
    }

    // MARK: - Data

    private func load() {
        // The fetch in flight checks on landing whether its range is still the one shown.
        guard !loading else { return }
        guard let key = apiKey() else {
            statusLine?.show("No API key set — add one in Settings.")
            return
        }
        loading = true
        let requested = range
        let requestedGeneration = generation
        Task {
            do {
                let fetched = try await fetchLivePower(apiKey: key, meter: meter, range: requested)
                if requestedGeneration == generation {
                    cache[requested] = fetched
                    if requested == range {
                        apply(fetched)
                        statusLine?.show("")
                    }
                }
            } catch {
                await invalidateSession(after: error)
                if requestedGeneration == generation, requested == range {
                    // A chart already up stays: a failed refresh says nothing about the readings
                    // it shows, and the footer says when they were fetched.
                    statusLine?.show(error.localizedDescription)
                    if cache[range] == nil { chart?.placeholder = "No live power to show" }
                }
            }
            loading = false
            // A range picked while this was busy returned early; show it now.
            if requestedGeneration == generation, requested != range, window?.isVisible == true { showRange() }
        }
    }

    private func apply(_ series: LivePowerSeries) {
        chart?.series = series
        chart?.placeholder = series.isEmpty ? "No readings from the Home Mini in the \(phrase(series.range))" : nil
        updateFooter(series)
    }

    private func phrase(_ range: LivePowerRange) -> String {
        switch range {
        case .hour: return "last hour"
        case .sixHours: return "last 6 hours"
        case .day: return "last 24 hours"
        }
    }

    /// The window's figures in words, so nothing the chart shows is reachable only by hovering.
    private func updateFooter(_ series: LivePowerSeries) {
        guard !series.isEmpty else {
            footer?.stringValue = "Updated \(formatted(series.fetchedAt, "HH:mm:ss", tz))"
            return
        }
        var parts = [String(format: "%.2f kWh in the %@", series.energyWh / 1000, phrase(series.range))]
        if let peak = series.peak {
            parts.append("peak \(powerText(peak.watts)) at \(formatted(series.slotStart(peak.index), "HH:mm", tz))")
        }
        parts.append(series.range.plotsDemand ? "readings every 10 seconds" : "five-minute averages")
        parts.append("updated \(formatted(series.fetchedAt, "HH:mm:ss", tz))")
        footer?.stringValue = parts.joined(separator: " · ")
    }
}
