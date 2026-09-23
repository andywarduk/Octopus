// One usage window. There is an instance per fuel, so electricity and gas each get their own
// window, week position, cache and controls without sharing state.

import Cocoa

@MainActor
final class UsageWindowController: NSObject {
    let fuel: Fuel
    /// How the key is read and whether a fetch may run at all.
    private let apiKey: () -> String?

    private var window: NSWindow?
    private var chart: UsageChartView?
    private var status: NSTextField?
    private var statusHeight: NSLayoutConstraint?
    private var footer: NSTextField?
    private var rangeLabel: NSTextField?
    private var forwardButton: NSButton?
    private var scaleControl: NSSegmentedControl?

    private var series = UsageSeries()
    private var cache: [String: CachedUsage] = [:]
    private var weeksBack = 0
    private var granularity: Granularity = .day
    private var loading = false
    /// Bumped when the meter or key changes, so a fetch already in flight for the old one is
    /// neither shown nor cached when it lands.
    private var generation = 0

    init(fuel: Fuel, apiKey: @escaping () -> String?) {
        self.fuel = fuel
        self.apiKey = apiKey
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if series.isEmpty { load() }
    }

    /// Called when the meter for this fuel changes: nothing already fetched still applies.
    func resetForMeterChange() {
        generation += 1
        cache.removeAll()
        series = UsageSeries()
        weeksBack = 0
        updateRange()
        clearChart(placeholder: "Loading…")
        if isVisible { load() }
    }

    // MARK: - Layout

    private func build() {
        let unitPicker = NSSegmentedControl(
            labels: [fuel.defaultEnergyLabel, "£"], trackingMode: .selectOne, target: self,
            action: #selector(unitChanged(_:)))
        unitPicker.selectedSegment = 0

        let scale = NSSegmentedControl(
            labels: ["Day", "Half Hour"], trackingMode: .selectOne, target: self,
            action: #selector(granularityChanged(_:)))
        scale.selectedSegment = 0

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
        // Wrap within the window rather than stretching the controls row off the edge.
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.cell?.wraps = true
        statusField.cell?.isScrollable = false
        statusField.translatesAutoresizingMaskIntoConstraints = false
        // Let the explicit height win when the row is collapsed to nothing.
        statusField.setContentCompressionResistancePriority(.init(249), for: .vertical)

        let controls = NSStackView(views: [back, range, forward, unitPicker, scale, reload])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        let chartView = UsageChartView()
        chartView.translatesAutoresizingMaskIntoConstraints = false

        let footerField = NSTextField(labelWithString: "")
        footerField.font = .systemFont(ofSize: 10)
        footerField.textColor = .tertiaryLabelColor
        footerField.translatesAutoresizingMaskIntoConstraints = false
        // Truncate rather than letting a long line set the window's width.
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
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        newWindow.title = fuel.windowTitle
        newWindow.contentView = container
        newWindow.isReleasedWhenClosed = false
        newWindow.setContentSize(CGSize(width: 620, height: 380))
        newWindow.contentMinSize = CGSize(width: 460, height: 300)
        // Offset the second window so it doesn't land exactly on the first.
        newWindow.center()
        if fuel != .electricity, var origin = newWindow.frame.origin as CGPoint? {
            origin.x += 28
            origin.y -= 28
            newWindow.setFrameOrigin(origin)
        }

        let height = statusField.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true

        window = newWindow
        chart = chartView
        status = statusField
        statusHeight = height
        footer = footerField
        rangeLabel = range
        forwardButton = forward
        scaleControl = scale
        updateRange()
        setStatus("")
    }

    // MARK: - Controls

    @objc private func previousWeek() { changeWeek(by: 1) }

    @objc private func nextWeek() { changeWeek(by: -1) }

    /// `by` counts weeks further into the past, so +1 steps back.
    private func changeWeek(by delta: Int) {
        let target = max(0, weeksBack + delta)
        guard target != weeksBack else { return }
        weeksBack = target
        updateRange()
        load()
    }

    @objc private func unitChanged(_ sender: NSSegmentedControl) {
        chart?.unit = sender.selectedSegment == 1 ? .money : .kwh
        updateFooter()
    }

    @objc private func granularityChanged(_ sender: NSSegmentedControl) {
        granularity = sender.selectedSegment == 1 ? .halfHour : .day
        apply()
    }

    @objc private func reload() {
        cache[cacheKey(weeksBack)] = nil
        load()
    }

    /// The row collapses when empty, so an error never permanently costs space.
    private func setStatus(_ text: String) {
        status?.stringValue = text
        status?.toolTip = text.isEmpty ? nil : text
        statusHeight?.constant = text.isEmpty ? 0 : 30
    }

    private func updateRange() {
        let tz = series.tz
        let window = usageDateWindow(weeksBack: weeksBack, days: 7, tz: tz)
        let cal = calendar(tz)
        let last = cal.date(byAdding: .day, value: -1, to: window.to) ?? window.to
        let sameMonth = cal.isDate(window.from, equalTo: last, toGranularity: .month)
        let from = formatted(window.from, sameMonth ? "d" : "d MMM", tz)
        rangeLabel?.stringValue = "\(from) – \(formatted(last, "d MMM", tz))"
        // Nothing to show past today, so forward stops at the current week.
        forwardButton?.isEnabled = weeksBack > 0
    }

    // MARK: - Data

    /// Meter and offset both matter: another meter's week is different data entirely.
    private func cacheKey(_ weeksBack: Int) -> String {
        "\(MeterPreference.savedId(fuel) ?? "auto")|\(weeksBack)"
    }

    /// Re-buckets the series already fetched; changing granularity never refetches.
    private func apply() {
        // A meter that only reports daily has nothing to show per half hour.
        scaleControl?.setEnabled(series.supportsHalfHour, forSegment: 1)
        if !series.supportsHalfHour {
            granularity = .day
            scaleControl?.selectedSegment = 0
        }
        chart?.placeholder = nil
        chart?.granularity = granularity
        chart?.tz = series.tz
        chart?.energyLabel = series.energyLabel
        chart?.periods = series.periods(granularity)
        updateRange()
        updateFooter()
    }

    /// Drops whatever is plotted. A stale chart left under an error message reads as current,
    /// and after a meter change it is another meter's data entirely.
    private func clearChart(placeholder: String?) {
        chart?.periods = []
        chart?.placeholder = placeholder
        footer?.stringValue = ""
    }

    func load() {
        // A request made while one is in flight is not dropped: the fetch checks on landing
        // whether it is still what is wanted, and loads again if not.
        guard !loading else { return }
        guard let key = apiKey() else {
            setStatus("No API key set — add one in Settings.")
            clearChart(placeholder: "No API key set")
            return
        }
        let key0 = cacheKey(weeksBack)
        if let hit = cache[key0], hit.isFresh() {
            series = hit.series
            setStatus("")
            apply()
            return
        }

        series = UsageSeries()
        clearChart(placeholder: "Loading…")
        loading = true
        setStatus("Loading…")
        let requested = weeksBack
        let requestedGeneration = generation
        Task {
            // The week, the meter or the key may all have changed while this was in flight.
            var current: Bool { requestedGeneration == generation && key0 == cacheKey(weeksBack) }
            do {
                let fetched = try await fetchUsage(apiKey: key, days: 7, weeksBack: requested, fuel: fuel)
                // Another week's data is still worth keeping; another meter's or key's is not.
                if requestedGeneration == generation {
                    cache[key0] = CachedUsage(
                        series: fetched, fetchedAt: Date(), complete: fetched.isComplete)
                    trimCache()
                }
                if current {
                    series = fetched
                    apply()
                    setStatus("")
                }
            } catch {
                await invalidateSession(after: error)
                if current {
                    setStatus(error.localizedDescription)
                    series = UsageSeries()
                    clearChart(placeholder: "No usage to show")
                }
            }
            loading = false
            // What is wanted now was asked for while this was busy, and that request returned
            // early. Without this the window sat on "Loading…" until the next click.
            if !current, isVisible { load() }
        }
    }

    /// Keep a season or so; beyond that the oldest fetch goes first.
    private func trimCache(limit: Int = 14) {
        guard cache.count > limit else { return }
        for key in cache.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt })
            .prefix(cache.count - limit).map(\.key)
        {
            cache[key] = nil
        }
    }

    private func updateFooter() {
        let periods = chart?.periods ?? []
        guard !periods.isEmpty else {
            footer?.stringValue = ""
            return
        }
        let unit = chart?.unit ?? .kwh
        let standing = periods.reduce(0) { $0 + $1.standingPence }
        let shown = visibleBands(unit, granularity)
        let total = periods.reduce(0) { $0 + $1.total(unit, shown) }
        let label = series.energyLabel
        // Say what a bar is: per half hour, energy is half the power drawn — 7 kW reads 3.5 kWh.
        let scale =
            granularity == .day
            ? "\(periods.count) days · each bar is one day"
            : "\(periods.count) half hours · each bar is 30 minutes of energy, not power"
        var text = "\(scale) · \(formatUsage(total, unit, withUnit: true, energyLabel: label)) total"
        let pending = periods.filter { !$0.hasData }.count
        if pending > 0 {
            let noun = granularity == .day ? "day" : "half hour"
            text += " · \(pending) \(noun)\(pending == 1 ? "" : "s") not published yet"
        }
        if !series.supportsHalfHour {
            text += " · this meter reports daily only"
        }
        // Only mention it when it isn't in the stack — in money it is, so the total covers it.
        if standing > 0, !shown.contains(.standing) {
            text += " · standing charge \(formatUsage(standing, .money)) not shown"
        }
        footer?.stringValue = text
    }
}
