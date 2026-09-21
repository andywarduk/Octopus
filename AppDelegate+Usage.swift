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

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadUsage))
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [picker, scale, reload, status])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        let chart = UsageChartView()
        chart.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(labelWithString: "")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor

        let container = NSView()
        for view in [controls, chart, footer] { container.addSubview(view) }
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            chart.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            chart.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            chart.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            footer.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
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

        usageWindow = window
        usageChart = chart
        usageStatus = status
        usageFooter = footer
        usageScale = scale
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
        usageChart?.granularity = usageGranularity
        usageChart?.tz = usageSeries.tz
        usageChart?.periods = usageSeries.periods(usageGranularity)
        updateUsageFooter()
    }

    @objc func reloadUsage() {
        usageSeries = UsageSeries()
        loadUsage()
    }

    func loadUsage() {
        guard !usageLoading else { return }
        guard let key = apiKey else {
            usageStatus?.stringValue = "No API key set — add one in Settings."
            return
        }
        usageLoading = true
        usageStatus?.stringValue = "Loading…"
        Task {
            do {
                usageSeries = try await fetchUsage(apiKey: key, days: 7)
                applyUsageSeries()
                usageStatus?.stringValue = ""
            } catch {
                usageStatus?.stringValue = error.localizedDescription
            }
            usageLoading = false
            updateUsageFooter()
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
