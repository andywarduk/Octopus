// The carbon intensity window. One instance; the source is switchable rather than fixed, because
// the two sources answer the same question with different coverage — see CarbonIntensity.swift.

import Cocoa

@MainActor
final class CarbonWindowController: NSObject {
    private let apiKey: () -> String?
    /// The postcode of the property whose electricity meter is selected. Both APIs are regional,
    /// so without one there is nothing to ask about.
    private let postcode: () -> String?

    private var window: NSWindow?
    private var chart: CarbonChartView?
    private var statusLine: StatusLine?
    private var footer: NSTextField?
    private var sourceControl: NSSegmentedControl?
    private var modeControl: NSSegmentedControl?
    private var rangeLabel: NSTextField?
    private var backButton: NSButton?
    private var forwardButton: NSButton?

    private var series = CarbonSeries()
    /// Keyed by source and period, so switching either doesn't refetch what's already in hand.
    private var cache: [String: CarbonSeries] = [:]
    private var source: CarbonSource = .nationalGrid
    private var period: CarbonPeriod = .forecast
    private var mode: CarbonMode = .intensity
    private var loading = false
    /// Bumped when the meter or key changes: the postcode may differ, so a fetch in flight for the
    /// old one is neither shown nor cached.
    private var generation = 0

    /// Moves the "now" rule and the footer's current reading along while the window stays open.
    /// They were set once per load, so a window left up all afternoon still marked the morning.
    private var clock: Timer?

    /// The chart's timezone throughout: both sources are British and report in UTC.
    private let tz = londonTimeZone

    init(apiKey: @escaping () -> String?, postcode: @escaping () -> String?) {
        self.apiKey = apiKey
        self.postcode = postcode
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if series.isEmpty { load() }
        startClock()
    }

    /// A minute is plenty: the rule moves about a pixel a minute across 48 hours of chart. It only
    /// runs while the window is up, and stops itself once the window is closed.
    private func startClock() {
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClock() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tickClock() {
        guard window?.isVisible == true else {
            clock?.invalidate()
            clock = nil
            return
        }
        guard !series.isEmpty else { return }
        chart?.now = Date()
        updateFooter()
    }

    /// The meter choice drives which postcode is used, so a change invalidates everything.
    func resetForMeterChange() {
        generation += 1
        cache.removeAll()
        series = CarbonSeries()
        clearChart(placeholder: "Loading…")
        if window?.isVisible == true { load() }
    }

    // MARK: - Layout

    private func build() {
        // National Grid first, and the default: it needs no API key, covers 48 hours rather than
        // 24, and reports the generation mix.
        let sources = NSSegmentedControl(
            labels: CarbonSource.allCases.map(\.title), trackingMode: .selectOne, target: self,
            action: #selector(sourceChanged(_:)))
        sources.selectedSegment = CarbonSource.allCases.firstIndex(of: source) ?? 0

        let modes = NSSegmentedControl(
            labels: CarbonMode.allCases.map(\.title), trackingMode: .selectOne, target: self,
            action: #selector(modeChanged(_:)))
        modes.selectedSegment = 0

        let back = chevronButton("chevron.left", "Previous week", target: self, action: #selector(previousWeek))
        let forward = chevronButton("chevron.right", "Next week", target: self, action: #selector(nextWeek))
        let range = makeWeekRangeLabel()
        let reload = NSButton(title: "Reload", target: self, action: #selector(reload))

        let controls = NSStackView(views: [back, range, forward, sources, modes, reload])
        controls.spacing = 10
        let status = StatusLine()
        let chartView = CarbonChartView()
        let footerField = makeFooterField()
        let container = chartWindowContent(
            controls: controls, status: status.field, chart: chartView, footer: footerField)

        let newWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        newWindow.title = "Carbon Intensity"
        newWindow.contentView = container
        newWindow.isReleasedWhenClosed = false
        // Wider than the usage windows: the controls row carries two segmented controls and the
        // week stepper, and at 640 it wrapped off the edge.
        newWindow.setContentSize(CGSize(width: 780, height: 400))
        newWindow.contentMinSize = CGSize(width: 620, height: 320)
        newWindow.center()
        // Offset from the usage windows, which cascade from the centre, so they don't stack exactly.
        var origin = newWindow.frame.origin
        origin.x += 56
        origin.y -= 56
        newWindow.setFrameOrigin(origin)

        window = newWindow
        chart = chartView
        statusLine = status
        footer = footerField
        sourceControl = sources
        modeControl = modes
        rangeLabel = range
        backButton = back
        forwardButton = forward
        updateControls()
    }

    // MARK: - Controls

    @objc private func sourceChanged(_ sender: NSSegmentedControl) {
        let picked = CarbonSource.allCases.indices.contains(sender.selectedSegment)
            ? CarbonSource.allCases[sender.selectedSegment] : .nationalGrid
        guard picked != source else { return }
        source = picked
        // Octopus only forecasts, so moving to it drops any history position rather than
        // erroring. Moving back to National Grid stays where it landed.
        if !picked.supportsHistory { period = .forecast }
        updateControls()
        load()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let picked = CarbonMode.allCases.indices.contains(sender.selectedSegment)
            ? CarbonMode.allCases[sender.selectedSegment] : .intensity
        guard picked != mode else { return }
        mode = picked
        // Same readings, drawn differently: nothing to refetch.
        chart?.mode = mode
        updateFooter()
    }

    @objc private func previousWeek() { step(by: 1) }

    @objc private func nextWeek() { step(by: -1) }

    /// `by` counts weeks further into the past. Stepping back from the forecast lands on the
    /// current week; stepping forward past it returns to the forecast.
    private func step(by delta: Int) {
        guard source.supportsHistory else { return }
        let next: CarbonPeriod
        switch period {
        case .forecast:
            guard delta > 0 else { return }
            next = .week(back: 0)
        case .week(let back):
            let target = back + delta
            next = target < 0 ? .forecast : .week(back: target)
        }
        guard next != period else { return }
        period = next
        updateControls()
        load()
    }

    @objc private func reload() {
        cache[cacheKey(source, period)] = nil
        load()
    }

    /// Enables only what the current source can actually do, and says where we are.
    private func updateControls() {
        let canGoBack = source.supportsHistory
        backButton?.isEnabled = canGoBack
        forwardButton?.isEnabled = canGoBack && period != .forecast
        switch period {
        case .forecast:
            rangeLabel?.stringValue = source == .octopus ? "Next 24 hours" : "Next 48 hours"
        case .week(let back):
            rangeLabel?.stringValue = weekRangeText(weeksBack: back, tz: tz)
        }
        // The mix is National Grid's; Octopus never sends one. Fall back rather than showing an
        // empty chart under a selected tab.
        let mixAvailable = series.isEmpty ? source.supportsHistory : series.hasMix
        modeControl?.setEnabled(mixAvailable, forSegment: 1)
        if !mixAvailable, mode == .mix {
            mode = .intensity
            modeControl?.selectedSegment = 0
            chart?.mode = .intensity
        }
    }

    /// A stale chart left under an error message reads as current, and after a source change it is
    /// the other source's data.
    private func clearChart(placeholder: String?) {
        chart?.readings = []
        chart?.placeholder = placeholder
        footer?.stringValue = ""
    }

    // MARK: - Data

    private func cacheKey(_ source: CarbonSource, _ period: CarbonPeriod) -> String {
        "\(source.rawValue)|\(period.weeksBack.map(String.init) ?? "forecast")"
    }

    private func apply() {
        chart?.placeholder = nil
        chart?.tz = tz
        chart?.now = Date()
        chart?.mode = mode
        chart?.readings = series.readings
        updateControls()
        updateFooter()
    }

    func load() {
        guard !loading else { return }
        guard let postcode = postcode(), !outwardCode(postcode).isEmpty else {
            statusLine?.show("No postcode for the selected property — pick a meter in Settings.")
            clearChart(placeholder: "No postcode")
            return
        }
        let requestedKey = cacheKey(source, period)
        if let hit = cache[requestedKey], hit.isFresh() {
            series = hit
            statusLine?.show("")
            apply()
            return
        }

        series = CarbonSeries()
        clearChart(placeholder: "Loading…")
        loading = true
        statusLine?.show("Loading…")
        let requestedSource = source
        let requestedPeriod = period
        let requestedGeneration = generation
        let key = apiKey()
        Task {
            // Either control, or the meter behind the postcode, may have changed in flight.
            var current: Bool {
                requestedGeneration == generation && requestedSource == source && requestedPeriod == period
            }
            do {
                let fetched = try await fetchCarbon(
                    source: requestedSource, period: requestedPeriod, apiKey: key,
                    postcode: postcode, tz: tz)
                if requestedGeneration == generation { cache[requestedKey] = fetched }
                if current {
                    series = fetched
                    apply()
                    statusLine?.show("")
                }
            } catch {
                if requestedSource == .octopus { await invalidateSession(after: error) }
                if current {
                    statusLine?.show(error.localizedDescription)
                    series = CarbonSeries()
                    clearChart(placeholder: "No carbon intensity to show")
                    updateControls()
                }
            }
            loading = false
            // A step or source change made while this was busy returned early; load it now, or
            // the window sits on "Loading…" until the next click.
            if !current, window?.isVisible == true { load() }
        }
    }

    private func updateFooter() {
        guard !series.isEmpty else {
            footer?.stringValue = ""
            return
        }
        var parts = ["\(series.readings.count) half hours"]
        if let region = series.region { parts.append(region) }
        parts.append(series.outward)
        if mode == .mix {
            // The average over the window, the same figures as the legend's percentages. Coal is
            // still summed although Britain burned its last in 2024 and the figure is now always
            // zero: the API still carries the fuel, and naming the total "fossil" rather than
            // listing the fuels means a restart would be counted without a wording change.
            let mean = averageMix(series.readings)
            let fossil = (mean[.gas] ?? 0) + (mean[.coal] ?? 0)
            parts.append(String(format: "fossil fuels %.0f%% on average", fossil))
            // Bar heights are GB-wide while the intensity view is regional, and the mix behind
            // them can be either. Both have to be said, or the chart implies one scope.
            parts.append(series.mixBasis)
            if series.scaledToDemand {
                let now = Date()
                // The half hour in progress is a different case from the far end of the window:
                // it is not missing, it is not published yet, and it fills in within 30 minutes.
                let gaps = series.readings.map { demandGap($0, now: now) }
                let running = gaps.filter { $0 == .stillRunning }.count
                let ahead = gaps.filter { $0 == .beyondForecast }.count
                var text = "bars are GB demand"
                if running > 0 { text += " · this half hour is still running" }
                if ahead > 0 { text += " · \(ahead) half hours not forecast yet" }
                parts.append(text)
            } else if series.hasDemand {
                // Some demand came back, but not enough of the window for the axis to be worth
                // changing, so the chart is drawing shares. Say that, rather than the opposite.
                let known = series.readings.filter { $0.demandMW != nil }.count
                parts.append(
                    "bars show shares — GB demand for only \(known) of \(series.readings.count) half hours")
            } else {
                parts.append("GB demand unavailable — bars show shares")
            }
        } else {
            if let current = series.current() {
                parts.append("now \(formatGrams(current.grams)) · \(current.index.title.lowercased())")
            }
            if let cleanest = series.cleanest {
                parts.append(
                    "cleanest \(formatted(cleanest.start, "EEE HH:mm", tz)) at \(formatGrams(cleanest.grams))")
            }
        }
        if series.source == .octopus {
            parts.append("Octopus forecasts 24 hours, with no history and no generation mix")
        }
        footer?.stringValue = parts.joined(separator: " · ")
    }
}
