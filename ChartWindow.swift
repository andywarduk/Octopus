// The pieces the usage and carbon windows share: week-stepping chevrons and the range between
// them, a status line that collapses when empty, and a one-line footer under the chart.

import Cocoa

/// A week-stepping button, with a text fallback should the symbol be missing.
@MainActor
func chevronButton(_ symbol: String, _ description: String, target: AnyObject, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    let button = image.map { NSButton(image: $0, target: target, action: action) }
        ?? NSButton(title: description, target: target, action: action)
    button.bezelStyle = .rounded
    button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    return button
}

/// The label between the chevrons, wide enough that stepping weeks doesn't jostle the row.
@MainActor
func makeWeekRangeLabel() -> NSTextField {
    let range = NSTextField(labelWithString: "")
    range.alignment = .center
    range.translatesAutoresizingMaskIntoConstraints = false
    range.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    return range
}

/// "14 – 20 Sep", or "28 Sep – 4 Oct" across a month end: the week `usageDateWindow` gives.
func weekRangeText(weeksBack: Int, tz: TimeZone) -> String {
    let window = usageDateWindow(weeksBack: weeksBack, days: 7, tz: tz)
    let cal = calendar(tz)
    let last = cal.date(byAdding: .day, value: -1, to: window.to) ?? window.to
    let sameMonth = cal.isDate(window.from, equalTo: last, toGranularity: .month)
    return "\(formatted(window.from, sameMonth ? "d" : "d MMM", tz)) – \(formatted(last, "d MMM", tz))"
}

/// The row under the controls. It collapses when empty, so an error never permanently costs space.
@MainActor
final class StatusLine {
    let field = NSTextField(labelWithString: "")
    private let height: NSLayoutConstraint

    init() {
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        // Wrap within the window rather than stretching the controls row off the edge.
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        // Let the explicit height win when the row is collapsed to nothing.
        field.setContentCompressionResistancePriority(.init(249), for: .vertical)
        height = field.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    func show(_ text: String) {
        field.stringValue = text
        field.toolTip = text.isEmpty ? nil : text
        height.constant = text.isEmpty ? 0 : 30
    }
}

/// The line under the chart. Truncates rather than letting a long line set the window's width.
@MainActor
func makeFooterField() -> NSTextField {
    let footer = NSTextField(labelWithString: "")
    footer.font = .systemFont(ofSize: 10)
    footer.textColor = .tertiaryLabelColor
    footer.translatesAutoresizingMaskIntoConstraints = false
    footer.maximumNumberOfLines = 1
    footer.lineBreakMode = .byTruncatingTail
    return footer
}

/// Controls, status line, chart and footer, top to bottom, with the margins both windows use.
@MainActor
func chartWindowContent(controls: NSView, status: NSView, chart: NSView, footer: NSView) -> NSView {
    let container = NSView()
    for view in [controls, status, chart, footer] {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
    }
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
    return container
}
