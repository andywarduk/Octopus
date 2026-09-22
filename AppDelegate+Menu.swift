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
            symbol = cheap ? "bolt.fill" : "bolt"
            color = cheap ? .systemGreen : nil
            if !s.hasCheapRate {
                tip = "Single rate: \(pence(s.peakRate))"
            } else {
                tip = cheap ? "Cheap rate: \(pence(s.cheapRate))" : "Standard rate: \(pence(s.peakRate))"
            }
        } else {
            symbol = "exclamationmark.triangle"
            tip = lastError ?? "Loading…"
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        if let color {
            image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        } else {
            image?.isTemplate = true
        }
        item.button?.image = image
        item.button?.toolTip = tip
    }

    // Called before the menu is shown, so rebuilding here is safe.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        if Date().timeIntervalSince(snapshot?.fetched ?? .distantPast) > 60 { refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    /// A custom-view item: it never highlights on hover, and unlike a disabled item it isn't dimmed.
    func infoItem(_ title: String, font: NSFont, color: NSColor) -> NSMenuItem {
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = color
        label.sizeToFit()
        let inset = NSPoint(x: 14, y: 3)
        let view = NSView(frame: NSRect(
            x: 0, y: 0, width: label.frame.width + inset.x * 2, height: label.frame.height + inset.y * 2))
        label.frame.origin = inset
        view.autoresizingMask = [.width]
        view.addSubview(label)
        let mi = NSMenuItem()
        mi.view = view
        return mi
    }

    func rebuildMenu() {
        // Tearing items out from under an open menu makes it flicker or close. menuNeedsUpdate
        // rebuilds before each display, so there's nothing to catch up on afterwards.
        guard !menuIsOpen else { return }
        menu.removeAllItems()
        if let s = snapshot {
            for line in menuLines(s, now: Date()) {
                switch line {
                case .separator:
                    menu.addItem(.separator())
                case .header(let t):
                    menu.addItem(infoItem(t, font: .boldSystemFont(ofSize: NSFont.systemFontSize), color: .labelColor))
                case .text(let t):
                    let detail = t.hasPrefix("    ") || t.hasPrefix("Updated")
                    menu.addItem(infoItem(t, font: .menuFont(ofSize: 0), color: detail ? .secondaryLabelColor : .labelColor))
                }
            }
        } else {
            menu.addItem(infoItem(loading ? "Loading…" : "No data yet", font: .menuFont(ofSize: 0), color: .labelColor))
        }
        if let e = lastError {
            menu.addItem(infoItem("⚠︎ \(e)", font: .menuFont(ofSize: 0), color: .labelColor))
        }
        menu.addItem(.separator())
        // A usage window is only offered for a fuel the account actually has. Until discovery
        // finishes both are shown, since hiding them on "not known yet" would be wrong.
        func add(_ items: [(String, Selector, String)]) {
            for (title, action, key) in items {
                let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
                mi.target = self
                menu.addItem(mi)
            }
        }

        // The windows this app opens.
        var windows: [(String, Selector, String)] = []
        if hasMeters(.electricity) { windows.append(("Electricity Use…", #selector(showUsage), "u")) }
        if hasMeters(.gas) { windows.append(("Gas Use…", #selector(showGasUsage), "g")) }
        // Not gated on a meter: it needs a postcode rather than a supply point, and the window
        // says so plainly if there isn't one.
        windows.append(("Carbon Intensity…", #selector(showCarbon), "c"))
        add(windows)

        // Acting on the app itself, rather than opening something.
        menu.addItem(.separator())
        add([
            ("Refresh Now", #selector(refreshNow), "r"),
            ("Settings…", #selector(showSettings), ","),
            ("Quit", #selector(quit), "q"),
        ])
    }
}
