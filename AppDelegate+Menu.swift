// Drawing the status item and building the menu that drops out of it.

import Cocoa

extension AppDelegate {
    /// - Parameter intervals: this tick's cheap intervals, when the caller has them already.
    func updateIcon(intervals: [Interval]? = nil) {
        let symbol: String
        var color: NSColor?
        var tip: String
        if let s = snapshot, lastError == nil || Date().timeIntervalSince(s.fetched) < 900 {
            let now = Date()
            let cheap = currentInterval(intervals ?? cheapIntervals(s, now: now), now: now) != nil
            let carbon = currentCarbon(now: now)
            symbol = statusSymbol(cheap: cheap, lowCarbon: carbon.map { carbonIsLow($0.grams) })
            color = cheap ? .systemGreen : nil
            tip = statusTip(s, cheap: cheap, carbon: carbon)
        } else {
            symbol = "exclamationmark.triangle"
            tip = lastError ?? "Loading…"
        }
        // Every 30 seconds this is usually the same answer as last time; rebuilding the symbol image
        // and resetting the button would redraw the menu bar item for nothing.
        let state = "\(symbol)|\(color == nil ? "" : "green")|\(tip)"
        guard state != shownIcon else { return }
        shownIcon = state
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        if let color {
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        } else {
            image?.isTemplate = true
        }
        if let button = item.button {
            button.image = image
            // A nil symbol image leaves a zero-width, invisible-but-clickable status item, which
            // reads as "the app didn't launch". Fall back to text so the item is always visible.
            button.title = image == nil ? "⚡" : ""
            button.toolTip = tip
        }
    }

    // Called before the menu is shown, so rebuilding here is safe.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        if Date().timeIntervalSince(snapshot?.fetched ?? .distantPast) > 60 { refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// A custom-view item: it never highlights on hover, and unlike a disabled item it isn't dimmed.
    /// `details` are drawn under the title in the subtitle style — smaller, secondary, and aligned
    /// with the title — so a non-clickable line reads like a clickable one's subtitle.
    func infoItem(_ title: String?, font: NSFont, color: NSColor, details: [String] = []) -> NSMenuItem {
        var labels: [NSTextField] = []
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = font
            label.textColor = color
            labels.append(label)
        }
        for detail in details {
            let label = NSTextField(labelWithString: detail)
            label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            labels.append(label)
        }
        for label in labels { label.sizeToFit() }
        let inset = NSPoint(x: 14, y: 3)
        let height = labels.reduce(0) { $0 + $1.frame.height } + inset.y * 2
        let width = (labels.map(\.frame.width).max() ?? 0) + inset.x * 2
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // Top down: the view is not flipped, so the first label sits highest.
        var y = height - inset.y
        for label in labels {
            y -= label.frame.height
            label.frame.origin = NSPoint(x: inset.x, y: y)
            view.addSubview(label)
        }
        view.autoresizingMask = [.width]
        let mi = NSMenuItem()
        mi.view = view
        return mi
    }

    func rebuildMenu() {
        // Tearing items out from under an open menu makes it flicker or close. menuNeedsUpdate
        // rebuilds before each display, so there's nothing to catch up on afterwards.
        guard !menuIsOpen else { return }
        menu.removeAllItems()
        // First, where it can't be missed: at the foot of the information it sat below the tariff
        // list, while the prices above it were quietly going stale.
        if let e = lastError {
            menu.addItem(infoItem("⚠︎ \(e)", font: .menuFont(ofSize: 0), color: .labelColor))
            if snapshot != nil { menu.addItem(.separator()) }
        }
        menuActions = []
        let now = Date()
        // The forecast only when it is for the meter now selected; see currentCarbon.
        let carbon = currentCarbon(now: now) == nil ? [] : carbonReadings
        if let s = snapshot {
            add(menuLines(s, now: now, carbon: carbon))
        } else {
            if loading || lastError == nil {
                // "No data yet" under an error only repeats it; "Loading…" still says a retry is running.
                menu.addItem(infoItem(loading ? "Loading…" : "No data yet", font: .menuFont(ofSize: 0), color: .labelColor))
            }
            // The carbon window needs no Octopus data, so it stays reachable without any.
            add(carbonLines(carbon, now: now, tz: TimeZone(identifier: "Europe/London") ?? .current))
        }

        // Acting on the app itself, rather than opening something. The windows open from the
        // sections they belong to: usage under each meter's tariff, carbon under its own figures.
        menu.addItem(.separator())
        for (title, action, key) in [
            ("Refresh Now", #selector(refreshNow), "r"),
            ("Settings…", #selector(showSettings), ","),
            ("Quit", #selector(quit), "q"),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
    }

    private func add(_ lines: [Line]) {
        // Usage items are numbered ⌘1, ⌘2… in the order their tariffs are listed, so every meter
        // gets one, not just the first of each fuel; past nine they go without. Carbon keeps ⌘C.
        var usageNumber = 0
        for line in lines {
            switch line {
            case .separator:
                menu.addItem(.separator())
            case .header(let t):
                menu.addItem(infoItem(t, font: .boldSystemFont(ofSize: NSFont.systemFontSize), color: .labelColor))
            case .text(let t):
                menu.addItem(infoItem(t, font: .menuFont(ofSize: 0), color: .labelColor))
            case .info(let title, let detail):
                // An empty title is a detail standing alone, such as the price footnote with no
                // line above it to belong to.
                menu.addItem(infoItem(
                    title.isEmpty ? nil : title, font: .menuFont(ofSize: 0), color: .labelColor,
                    details: detail.components(separatedBy: "\n")))
            case .action(let title, let action, let detail):
                let key: String
                switch action {
                case .carbon:
                    key = "c"
                case .usage:
                    usageNumber += 1
                    key = usageNumber <= 9 ? String(usageNumber) : ""
                }
                let item = NSMenuItem(title: title, action: #selector(openMenuAction(_:)), keyEquivalent: key)
                item.target = self
                item.tag = menuActions.count
                menuActions.append(action)
                // A tariff line doesn't say it opens anything, so the tooltip does.
                switch action {
                case .usage(let meter): item.toolTip = "Show \(meter.fuel.rawValue) use"
                case .carbon: item.toolTip = "Show carbon intensity"
                }
                if let detail, #available(macOS 14, *) {
                    item.subtitle = detail
                    menu.addItem(item)
                } else {
                    menu.addItem(item)
                    if let detail {
                        // No native subtitle before macOS 14: the same look, drawn as its own row.
                        menu.addItem(infoItem(nil, font: .menuFont(ofSize: 0), color: .labelColor, details: [detail]))
                    }
                }
            }
        }
    }
}
