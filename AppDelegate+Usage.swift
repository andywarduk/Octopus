// The Usage window: a week of electricity use as stacked columns, in kWh or pounds.

import Cocoa

extension AppDelegate {
    @objc func showUsage() {
        if usageWindow == nil { buildUsageWindow() }
        NSApp.activate(ignoringOtherApps: true)
        usageWindow?.makeKeyAndOrderFront(nil)
        if usageSeries.isEmpty { loadUsage() }
    }

    func buildUsageWindow() {
        let picker = NSSegmentedControl(
            labels: ["kWh", "£"], trackingMode: .selectOne, target: self, action: #selector(usageUnitChanged(_:)))
        picker.selectedSegment = 0

        let scale = NSSegmentedControl(
            labels: ["Day", "Half hour"], trackingMode: .selectOne, target: self,
            action: #selector(usageGranularityChanged(_:)))
        scale.selectedSegment = 0

        func chevron(_ symbol: String, _ description: String, _ action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            let button = image.map { NSButton(image: $0, target: self, action: action) }
                ?? NSButton(title: description, target: self, action: action)
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            return button
        }
        let back = chevron("chevron.left", "Previous week", #selector(usagePreviousWeek))
        let forward = chevron("chevron.right", "Next week", #selector(usageNextWeek))
        let range = NSTextField(labelWithString: "")
        range.alignment = .center
        range.translatesAutoresizingMaskIntoConstraints = false
        range.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadUsage))
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        // Wrap within the window rather than stretching the controls row off the edge.
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        status.cell?.wraps = true
        status.cell?.isScrollable = false
        status.translatesAutoresizingMaskIntoConstraints = false
        // Let the explicit height win when the row is collapsed to nothing.
        status.setContentCompressionResistancePriority(.init(249), for: .vertical)

        let controls = NSStackView(views: [back, range, forward, picker, scale, reload])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        let chart = UsageChartView()
        chart.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(labelWithString: "")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor

        let container = NSView()
        for view in [controls, status, chart, footer] { container.addSubview(view) }
        footer.translatesAutoresizingMaskIntoConstraints = false
        // Truncate rather than letting a long line set the window's width.
        footer.maximumNumberOfLines = 1
        footer.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            chart.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            chart.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            chart.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            footer.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Electricity Use"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 620, height: 380))
        window.contentMinSize = CGSize(width: 460, height: 300)
        window.center()

        let statusHeight = status.heightAnchor.constraint(equalToConstant: 0)
        statusHeight.isActive = true
        usageStatusHeight = statusHeight

        usageWindow = window
        usageChart = chart
        usageStatus = status
        usageFooter = footer
        usageScale = scale
        usageBack = back
        usageForward = forward
        usageRange = range
        updateUsageRange()
        setUsageStatus("")
    }

    /// The row collapses when empty, so an error never permanently costs space.
    func setUsageStatus(_ text: String) {
        usageStatus?.stringValue = text
        usageStatus?.toolTip = text.isEmpty ? nil : text
        usageStatusHeight?.constant = text.isEmpty ? 0 : 30
    }

    @objc func usagePreviousWeek() { changeWeek(by: 1) }

    @objc func usageNextWeek() { changeWeek(by: -1) }

    /// `by` counts weeks further into the past, so +1 steps back.
    func changeWeek(by delta: Int) {
        let target = max(0, usageWeeksBack + delta)
        guard target != usageWeeksBack else { return }
        usageWeeksBack = target
        updateUsageRange()
        loadUsage()
    }

    /// Meter and offset both matter: another meter's week is different data entirely.
    func usageCacheKey(_ weeksBack: Int) -> String {
        "\(MeterPreference.savedId ?? "auto")|\(weeksBack)"
    }

    func updateUsageRange() {
        let tz = usageSeries.tz
        let window = usageDateWindow(weeksBack: usageWeeksBack, days: 7, tz: tz)
        let cal = calendar(tz)
        let last = cal.date(byAdding: .day, value: -1, to: window.to) ?? window.to
        let sameMonth = cal.isDate(window.from, equalTo: last, toGranularity: .month)
        let from = formatted(window.from, sameMonth ? "d" : "d MMM", tz)
        usageRange?.stringValue = "\(from) – \(formatted(last, "d MMM", tz))"
        // Nothing to show past today, so forward stops at the current week.
        usageForward?.isEnabled = usageWeeksBack > 0
    }

    @objc func usageUnitChanged(_ sender: NSSegmentedControl) {
        usageChart?.unit = sender.selectedSegment == 1 ? .money : .kwh
        updateUsageFooter()
    }

    @objc func usageGranularityChanged(_ sender: NSSegmentedControl) {
        usageGranularity = sender.selectedSegment == 1 ? .halfHour : .day
        applyUsageSeries()
    }

    /// Re-buckets the series already fetched; changing granularity never refetches.
    func applyUsageSeries() {
        usageChart?.placeholder = nil
        usageChart?.granularity = usageGranularity
        usageChart?.tz = usageSeries.tz
        usageChart?.periods = usageSeries.periods(usageGranularity)
        updateUsageRange()
        updateUsageFooter()
    }

    @objc func reloadUsage() {
        usageCache[usageCacheKey(usageWeeksBack)] = nil
        loadUsage()
    }

    /// Drops whatever is plotted. A stale chart left under an error message reads as current,
    /// and after a meter change it is another meter's data entirely.
    func clearUsageChart(placeholder: String?) {
        usageChart?.periods = []
        usageChart?.placeholder = placeholder
        usageFooter?.stringValue = ""
    }

    func loadUsage() {
        guard !usageLoading else { return }
        guard let key = apiKey else {
            setUsageStatus("No API key set — add one in Settings.")
            clearUsageChart(placeholder: "No API key set")
            return
        }
        let cacheKey = usageCacheKey(usageWeeksBack)
        if let hit = usageCache[cacheKey], hit.isFresh() {
            usageSeries = hit.series
            setUsageStatus("")
            applyUsageSeries()
            return
        }

        usageSeries = UsageSeries()
        clearUsageChart(placeholder: "Loading…")
        usageLoading = true
        setUsageStatus("Loading…")
        let weeksBack = usageWeeksBack
        Task {
            do {
                let series = try await fetchUsage(apiKey: key, days: 7, weeksBack: weeksBack)
                let complete = series.periods(.day).allSatisfy(\.hasData)
                usageCache[cacheKey] = CachedUsage(series: series, fetchedAt: Date(), complete: complete)
                trimUsageCache()
                // The week may have been changed again while this was in flight.
                if weeksBack == usageWeeksBack {
                    usageSeries = series
                    applyUsageSeries()
                    setUsageStatus("")
                }
            } catch {
                if weeksBack == usageWeeksBack {
                    setUsageStatus(error.localizedDescription)
                    usageSeries = UsageSeries()
                    clearUsageChart(placeholder: "No usage to show")
                }
            }
            usageLoading = false
        }
    }

    /// Keep a season or so; beyond that the oldest fetch goes first.
    func trimUsageCache(limit: Int = 14) {
        guard usageCache.count > limit else { return }
        for key in usageCache.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt })
            .prefix(usageCache.count - limit).map(\.key)
        {
            usageCache[key] = nil
        }
    }

    func updateUsageFooter() {
        let periods = usageChart?.periods ?? []
        guard !periods.isEmpty else {
            usageFooter?.stringValue = ""
            return
        }
        let standing = periods.reduce(0) { $0 + $1.standingPence }
        let unit = usageChart?.unit ?? .kwh
        let total = periods.reduce(0) { $0 + $1.total(unit) }
        // Say what a bar is: in kWh a half hour reads half the power drawn, so a 7 kW charge is 3.5.
        let scale = usageGranularity == .day
            ? "\(periods.count) days · each bar is one day"
            : "\(periods.count) half hours · each bar is 30 minutes of energy, not power"
        var text = "\(scale) · \(formatUsage(total, unit, withUnit: true)) total"
        let pending = periods.filter { !$0.hasData }.count
        if pending > 0 {
            let noun = usageGranularity == .day ? "day" : "half hour"
            text += " · \(pending) \(noun)\(pending == 1 ? "" : "s") not published yet"
        }
        if standing > 0 {
            text += " · standing charge \(formatUsage(standing, .money)) not shown"
        }
        usageFooter?.stringValue = text
    }
}
