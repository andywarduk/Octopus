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
        liveItems = []
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
            add(carbonLines(carbon, now: now, tz: londonTimeZone))
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

    /// Rewrites the live power lines of an open menu with the snapshot just fetched.
    ///
    /// The one exception to rebuilding only in `menuNeedsUpdate`, and not a rebuild: the items stay,
    /// only their text changes. Without it the figure is whatever the last refresh got, up to five
    /// minutes old — and opening the menu is what asks for a fresh one, which lands a second later
    /// with the menu still open. If the lines no longer match the items one for one, a Mini paired
    /// or removed since the menu opened, it waits for the next opening.
    func updateLiveItems() {
        guard menuIsOpen, let s = snapshot else { return }
        let fresh = livePowerLines(s, now: Date()).compactMap { line -> (title: String, detail: String)? in
            if case .live(let title, _, let detail) = line { return (title, detail) }
            return nil
        }
        guard fresh.count == liveItems.count else { return }
        for (live, text) in zip(liveItems, fresh) {
            live.item.title = text.title
            if #available(macOS 14, *) {
                live.item.subtitle = text.detail
            } else if let label = live.detailRow?.view?.subviews.compactMap({ $0 as? NSTextField }).first {
                label.stringValue = text.detail
                label.sizeToFit()
            }
        }
    }

    private func add(_ lines: [Line]) {
        // Usage items are numbered ⌘1, ⌘2… in the order their tariffs are listed, so every meter
        // gets one, not just the first of each fuel; past nine they go without. Carbon keeps ⌘C,
        // and the first live power line takes ⌘L.
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
                var key = ""
                if case .usage = action {
                    usageNumber += 1
                    if usageNumber <= 9 { key = String(usageNumber) }
                }
                addAction(title, action, detail: detail, key: key)
            case .live(let title, let action, let detail):
                let added = addAction(title, action, detail: detail, key: liveItems.isEmpty ? "l" : "")
                liveItems.append(added)
            }
        }
    }

    /// An item that opens a window, with its detail as the subtitle — or, before macOS 14, as a row
    /// of its own drawn in the same style, which is returned so a live line can rewrite it.
    @discardableResult
    private func addAction(
        _ title: String, _ action: MenuAction, detail: String?, key: String
    ) -> (item: NSMenuItem, detailRow: NSMenuItem?) {
        let item = NSMenuItem(
            title: title, action: #selector(openMenuAction(_:)), keyEquivalent: action == .carbon ? "c" : key)
        item.target = self
        item.tag = menuActions.count
        menuActions.append(action)
        // A tariff line doesn't say it opens anything, so the tooltip does.
        switch action {
        case .usage(let meter): item.toolTip = "Show \(meter.fuel.rawValue) use"
        case .carbon: item.toolTip = "Show carbon intensity"
        case .livePower: item.toolTip = "Show live power"
        }
        menu.addItem(item)
        guard let detail else { return (item, nil) }
        if #available(macOS 14, *) {
            item.subtitle = detail
            return (item, nil)
        }
        // No native subtitle before macOS 14: the same look, drawn as its own row.
        let row = infoItem(nil, font: .menuFont(ofSize: 0), color: .labelColor, details: [detail])
        menu.addItem(row)
        return (item, row)
    }
}
