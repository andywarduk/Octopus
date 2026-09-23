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
    private var status: NSTextField?
    private var statusHeight: NSLayoutConstraint?
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

    /// The chart's timezone throughout: both sources are British and report in UTC.
    private let tz = TimeZone(identifier: "Europe/London") ?? .current

    init(apiKey: @escaping () -> String?, postcode: @escaping () -> String?) {
        self.apiKey = apiKey
        self.postcode = postcode
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if series.isEmpty { load() }
    }

    /// The meter choice drives which postcode is used, so a change invalidates everything.
    func resetForMeterChange() {
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

        func chevron(_ symbol: String, _ description: String, _ action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            let button = image.map { NSButton(image: $0, target: self, action: action) }
                ?? NSButton(title: description, target: self, action: action)
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            return button
        }
        let back = chevron("chevron.left", "Previous week", #selector(previousWeek))
        let forward = chevron("chevron.right", "Next week", #selector(nextWeek))

        let range = NSTextField(labelWithString: "")
        range.alignment = .center
        range.translatesAutoresizingMaskIntoConstraints = false
        range.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let reload = NSButton(title: "Reload", target: self, action: #selector(reload))

        let statusField = NSTextField(labelWithString: "")
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.cell?.wraps = true
        statusField.cell?.isScrollable = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.setContentCompressionResistancePriority(.init(249), for: .vertical)

        let controls = NSStackView(views: [back, range, forward, sources, modes, reload])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        let chartView = CarbonChartView()
        chartView.translatesAutoresizingMaskIntoConstraints = false

        let footerField = NSTextField(labelWithString: "")
        footerField.font = .systemFont(ofSize: 10)
        footerField.textColor = .tertiaryLabelColor
        footerField.translatesAutoresizingMaskIntoConstraints = false
        footerField.maximumNumberOfLines = 1
        footerField.lineBreakMode = .byTruncatingTail

        let container = NSView()
        for view in [controls, statusField, chartView, footerField] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            statusField.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            statusField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            chartView.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 8),
            chartView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            chartView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            footerField.topAnchor.constraint(equalTo: chartView.bottomAnchor, constant: 6),
            footerField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footerField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            footerField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

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
        // Offset from the two usage windows so three open windows don't stack exactly.
        var origin = newWindow.frame.origin
        origin.x += 56
        origin.y -= 56
        newWindow.setFrameOrigin(origin)

        let height = statusField.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true

        window = newWindow
        chart = chartView
        status = statusField
        statusHeight = height
        footer = footerField
        sourceControl = sources
        modeControl = modes
        rangeLabel = range
        backButton = back
        forwardButton = forward
        updateControls()
        setStatus("")
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
            let window = usageDateWindow(weeksBack: back, days: 7, tz: tz)
            let cal = calendar(tz)
            let last = cal.date(byAdding: .day, value: -1, to: window.to) ?? window.to
            let sameMonth = cal.isDate(window.from, equalTo: last, toGranularity: .month)
            rangeLabel?.stringValue =
                "\(formatted(window.from, sameMonth ? "d" : "d MMM", tz)) – \(formatted(last, "d MMM", tz))"
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

    private func setStatus(_ text: String) {
        status?.stringValue = text
        status?.toolTip = text.isEmpty ? nil : text
        statusHeight?.constant = text.isEmpty ? 0 : 30
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
            setStatus("No postcode for the selected property — pick a meter in Settings.")
            clearChart(placeholder: "No postcode")
            return
        }
        let key0 = cacheKey(source, period)
        if let hit = cache[key0], hit.isFresh() {
            series = hit
            setStatus("")
            apply()
            return
        }

        series = CarbonSeries()
        clearChart(placeholder: "Loading…")
        loading = true
        setStatus("Loading…")
        let requestedSource = source
        let requestedPeriod = period
        let key = apiKey()
        Task {
            do {
                let fetched = try await fetchCarbon(
                    source: requestedSource, period: requestedPeriod, apiKey: key,
                    postcode: postcode, tz: tz)
                cache[key0] = fetched
                // Either control may have been changed again while this was in flight.
                if requestedSource == source && requestedPeriod == period {
                    series = fetched
                    apply()
                    setStatus("")
                }
            } catch {
                if requestedSource == source && requestedPeriod == period {
                    setStatus(error.localizedDescription)
                    series = CarbonSeries()
                    clearChart(placeholder: "No carbon intensity to show")
                    updateControls()
                }
            }
            loading = false
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
            // The average over the window, which is what the legend's percentages are. Coal is
            // still summed although Britain burned its last in 2024 and the figure is now always
            // zero: the API still carries the fuel, and naming the total "fossil" rather than
            // listing the fuels means a restart would be counted without a wording change.
            let fossil = series.readings.reduce(0.0) { total, reading in
                total + reading.mix
                    .filter { [.gas, .coal].contains($0.fuel) }
                    .reduce(0) { $0 + $1.percent }
            } / Double(max(1, series.readings.count))
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
            if series.suspectCount > 0 {
                parts.append(
                    "\(series.suspectCount) half hour\(series.suspectCount == 1 ? "" : "s") greyed:"
                        + " the published mix is impossible")
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
