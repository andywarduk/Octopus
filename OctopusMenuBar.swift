// Octopus Energy menu bar app: shows whether you're on the cheap or standard rate,
// your car's charge level, and the upcoming cheap-rate windows.
//
// Build: ./build.sh     Run: open build/OctopusMenuBar.app
// The API key is entered from the menu (Set API Key…) and stored in the login Keychain.

import Cocoa
import Security
import UserNotifications

// MARK: - Model

struct Interval {
    var start: Date
    var end: Date
    var smart: Bool
}

struct Car {
    var name: String
    var soc: Double?
    var target: Int?
    var state: String?
    var asOf: Date?
}

struct Snapshot {
    var cheapRate: Double
    var peakRate: Double
    var windows: [(from: Int, to: Int)]  // minutes after local midnight
    var dispatches: [Interval]
    var cars: [Car]
    var tz: TimeZone
    var fetched: Date
}

enum Line {
    case header(String)
    case text(String)
    case separator
}

// MARK: - Rate logic (pure, so it can be tested without the network)

func calendar(_ tz: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal
}

/// Cheap intervals that haven't ended yet and start within the next 48 hours, merged and sorted.
func cheapIntervals(_ s: Snapshot, now: Date) -> [Interval] {
    let cal = calendar(s.tz)
    let today = cal.startOfDay(for: now)
    var all: [Interval] = []
    for offset in -1...2 {
        guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
        for w in s.windows {
            let endDay = w.to <= w.from ? cal.date(byAdding: .day, value: 1, to: day) ?? day : day
            guard
                let start = cal.date(bySettingHour: w.from / 60, minute: w.from % 60, second: 0, of: day),
                let end = cal.date(bySettingHour: w.to / 60, minute: w.to % 60, second: 0, of: endDay)
            else { continue }
            all.append(Interval(start: start, end: end, smart: false))
        }
    }
    all += s.dispatches
    let horizon = now.addingTimeInterval(48 * 3600)
    all = all.filter { $0.end > now && $0.start < horizon }.sorted { $0.start < $1.start }

    var merged: [Interval] = []
    for i in all {
        if var last = merged.last, i.start <= last.end {
            last.end = max(last.end, i.end)
            last.smart = last.smart && i.smart
            merged[merged.count - 1] = last
        } else {
            merged.append(i)
        }
    }
    return merged
}

func currentInterval(_ intervals: [Interval], now: Date) -> Interval? {
    intervals.first { $0.start <= now && now < $0.end }
}

func isCheap(_ s: Snapshot, now: Date) -> Bool {
    currentInterval(cheapIntervals(s, now: now), now: now) != nil
}

func formatted(_ date: Date, _ format: String, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.timeZone = tz
    f.dateFormat = format
    return f.string(from: date)
}

func dayLabel(_ date: Date, now: Date, _ tz: TimeZone) -> String {
    let cal = calendar(tz)
    if cal.isDate(date, inSameDayAs: now) { return "Today" }
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        return "Tomorrow"
    }
    return formatted(date, "EEE", tz)
}

func stamp(_ date: Date, now: Date, _ tz: TimeZone) -> String {
    "\(dayLabel(date, now: now, tz)) \(formatted(date, "HH:mm", tz))"
}

func pence(_ v: Double) -> String { String(format: "%.2fp/kWh", v) }

func menuLines(_ s: Snapshot, now: Date) -> [Line] {
    let tz = s.tz
    let cal = calendar(tz)
    let intervals = cheapIntervals(s, now: now)
    let active = currentInterval(intervals, now: now)
    var lines: [Line] = []

    if let active {
        lines.append(.header("Cheap rate now · \(pence(s.cheapRate))"))
        lines.append(.text("Back to standard at \(stamp(active.end, now: now, tz)) (\(pence(s.peakRate)))"))
    } else {
        lines.append(.header("Standard rate now · \(pence(s.peakRate))"))
        if let next = intervals.first {
            lines.append(.text("Cheap from \(stamp(next.start, now: now, tz)) (\(pence(s.cheapRate)))"))
        }
    }

    lines.append(.separator)
    lines.append(.header(s.cars.count == 1 ? "Car" : "Cars"))
    if s.cars.isEmpty { lines.append(.text("No smart devices found")) }
    for car in s.cars {
        if let soc = car.soc {
            var title = "\(car.name): \(Int(soc.rounded()))%"
            if let target = car.target { title += " (target \(target)%)" }
            lines.append(.text(title))
            var detail: [String] = []
            if let asOf = car.asOf { detail.append("as of \(formatted(asOf, "HH:mm", tz))") }
            if let state = car.state {
                detail.append(state.replacingOccurrences(of: "_", with: " ").lowercased())
            }
            if !detail.isEmpty { lines.append(.text("    " + detail.joined(separator: " · "))) }
        } else {
            lines.append(.text("\(car.name): no charge level reported"))
        }
    }

    lines.append(.separator)
    lines.append(.header("Upcoming cheap rate"))
    if intervals.isEmpty { lines.append(.text("None in the next 48 hours")) }
    for i in intervals.prefix(6) {
        let isActive = i.start <= now
        let from = isActive ? "Now" : stamp(i.start, now: now, tz)
        let sameDay = cal.isDate(i.start, inSameDayAs: i.end)
        let to = sameDay ? formatted(i.end, "HH:mm", tz) : stamp(i.end, now: now, tz)
        var text = "\(from) – \(to)"
        if i.smart { text += "  (smart charge)" }
        lines.append(.text(text))
    }

    lines.append(.separator)
    lines.append(.text("Updated \(formatted(s.fetched, "HH:mm", tz))"))
    return lines
}

// MARK: - Keychain

enum Keychain {
    static let service = "OctopusMenuBar"
    static let account = "api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - Octopus API

struct ApiError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func toDouble(_ any: Any?) -> Double? {
    if let s = any as? String { return Double(s) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}

func parseDate(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func minutes(_ hhmmss: String) -> Int? {
    let p = hhmmss.split(separator: ":").compactMap { Int($0) }
    return p.count >= 2 ? p[0] * 60 + p[1] : nil
}

func gql(_ query: String, _ variables: [String: Any] = [:], token: String? = nil) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api.octopus.energy/v1/graphql/")!, timeoutInterval: 30)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ApiError(message: "Unexpected response")
    }
    if let errors = body["errors"] as? [[String: Any]], let first = errors.first {
        throw ApiError(message: first["message"] as? String ?? "GraphQL error")
    }
    return body["data"] as? [String: Any] ?? [:]
}

let fallbackWindows = [(from: 23 * 60 + 30, to: 5 * 60 + 30)]

func fetchSnapshot(apiKey: String) async throws -> Snapshot {
    let auth = try await gql(
        "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", ["k": apiKey])
    guard let token = (auth["obtainKrakenToken"] as? [String: Any])?["token"] as? String else {
        throw ApiError(message: "Login failed")
    }

    let who = try await gql("{viewer{accounts{number}}}", token: token)
    guard
        let accounts = (who["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]],
        let account = accounts.first?["number"] as? String
    else { throw ApiError(message: "No account found") }

    let agr = try await gql(
        """
        query($a:String!){account(accountNumber:$a){electricityAgreements(active:true){
          meterPoint{mpan direction}
          timeOfUseScheme{timezone timeslots{timeslot activeFrom activeTo}}
        }}}
        """, ["a": account], token: token)
    let agreements = ((agr["account"] as? [String: Any])?["electricityAgreements"] as? [[String: Any]]) ?? []
    let imports = agreements.filter {
        (($0["meterPoint"] as? [String: Any])?["direction"] as? String)?.uppercased() != "EXPORT"
    }
    guard let agreement = imports.first, let mpan = (agreement["meterPoint"] as? [String: Any])?["mpan"] as? String
    else { throw ApiError(message: "No electricity import meter found") }

    let now = Date()
    let iso = ISO8601DateFormatter()
    let ratesQuery = """
        query($a:String!,$m:String!,$s:DateTime!,$e:DateTime!,$n:Int!){
          applicableRates(accountNumber:$a,mpxn:$m,startAt:$s,endAt:$e,first:$n){edges{node{value}}}
          plannedDispatches(accountNumber:$a){start end}
          completedDispatches(accountNumber:$a){start end}
        }
        """
    var ratesData: [String: Any]?
    var lastError = ""
    for size in [100, 50, 25, 10] {
        do {
            ratesData = try await gql(
                ratesQuery,
                [
                    "a": account, "m": mpan, "n": size,
                    "s": iso.string(from: now), "e": iso.string(from: now.addingTimeInterval(24 * 3600)),
                ], token: token)
            break
        } catch let e as ApiError {
            lastError = e.message
            if !e.message.lowercased().contains("pagination") { throw e }
        }
    }
    guard let rd = ratesData else { throw ApiError(message: lastError) }

    let edges = ((rd["applicableRates"] as? [String: Any])?["edges"] as? [[String: Any]]) ?? []
    let values = edges.compactMap { toDouble(($0["node"] as? [String: Any])?["value"]) }
    guard let cheap = values.min(), let peak = values.max() else { throw ApiError(message: "No rates returned") }

    let scheme = agreement["timeOfUseScheme"] as? [String: Any]
    let tz = TimeZone(identifier: scheme?["timezone"] as? String ?? "") ?? TimeZone(identifier: "Europe/London")!
    var windows: [(from: Int, to: Int)] = []
    for slot in (scheme?["timeslots"] as? [[String: Any]]) ?? [] {
        let name = (slot["timeslot"] as? String ?? "").lowercased()
        guard ["off", "cheap", "night"].contains(where: name.contains),
            let from = minutes(slot["activeFrom"] as? String ?? ""),
            let to = minutes(slot["activeTo"] as? String ?? "")
        else { continue }
        windows.append((from, to))
    }
    if windows.isEmpty { windows = fallbackWindows }

    let dispatchRows = ((rd["plannedDispatches"] as? [[String: Any]]) ?? []) + ((rd["completedDispatches"] as? [[String: Any]]) ?? [])
    let dispatches = dispatchRows.compactMap { row -> Interval? in
        guard let s = parseDate(row["start"]), let e = parseDate(row["end"]) else { return nil }
        return Interval(start: s, end: e, smart: true)
    }

    var cars: [Car] = []
    do {
        let dev = try await gql(
            """
            query($a:String!){devices(accountNumber:$a){
              __typename id name
              ... on SmartFlexVehicle{
                make model
                status{... on SmartFlexVehicleStatus{currentState stateOfCharge{value timestamp}}}
                chargingPreferences{weekdayTargetSoc weekendTargetSoc}
              }
              ... on SmartFlexChargePoint{
                status{... on SmartFlexChargePointStatus{currentState stateOfCharge{value timestamp}}}
              }
            }}
            """, ["a": account], token: token)
        let weekend = calendar(tz).isDateInWeekend(now)
        for d in (dev["devices"] as? [[String: Any]]) ?? [] {
            let type = d["__typename"] as? String
            guard type == "SmartFlexVehicle" || type == "SmartFlexChargePoint" else { continue }
            let status = d["status"] as? [String: Any]
            let soc = status?["stateOfCharge"] as? [String: Any]
            let prefs = d["chargingPreferences"] as? [String: Any]
            let label = [d["make"], d["model"]].compactMap { $0 as? String }.joined(separator: " ")
            cars.append(
                Car(
                    name: label.isEmpty ? (d["name"] as? String ?? "Vehicle") : label,
                    soc: toDouble(soc?["value"]),
                    target: (prefs?[weekend ? "weekendTargetSoc" : "weekdayTargetSoc"] as? NSNumber)?.intValue,
                    state: status?["currentState"] as? String,
                    asOf: parseDate(soc?["timestamp"])))
        }
    } catch {
        // Charge level is secondary; the rate display still works without it.
    }

    return Snapshot(cheapRate: cheap, peakRate: peak, windows: windows, dispatches: dispatches, cars: cars, tz: tz, fetched: now)
}

// MARK: - App

/// Menu-bar-only apps have no bundle icon, so dialogs show a generic one; draw one instead.
func makeAppIcon() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
        let body = rect.insetBy(dx: 32, dy: 32)
        let shape = NSBezierPath(roundedRect: body, xRadius: 100, yRadius: 100)
        NSGradient(
            starting: NSColor(red: 0.42, green: 0.16, blue: 0.85, alpha: 1),
            ending: NSColor(red: 0.13, green: 0.05, blue: 0.35, alpha: 1)
        )?.draw(in: shape, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: 260, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        {
            let size = bolt.size
            bolt.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var snapshot: Snapshot?
    var lastError: String?
    var loading = false
    /// Read from the Keychain once at launch, never while the menu is open: the system's unlock
    /// prompt can't take keyboard input while menu tracking has focus.
    var apiKey: String?
    /// Cheap-interval start times already announced, so each one alerts once.
    var notified = Set<Date>()
    static let leadTime: TimeInterval = 10 * 60
    var notifyEnabled: Bool { UserDefaults.standard.object(forKey: "notifyBeforeCheap") as? Bool ?? true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = makeAppIcon()
        apiKey = Keychain.read()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateIcon()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        updateIcon()
        checkUpcomingCheap()
        if Date().timeIntervalSince(snapshot?.fetched ?? .distantPast) > 300 { refresh() }
    }

    /// Alerts once when a cheap window (fixed or smart-charge) is about to start.
    func checkUpcomingCheap() {
        guard notifyEnabled, let s = snapshot else { return }
        let now = Date()
        let intervals = cheapIntervals(s, now: now)
        guard currentInterval(intervals, now: now) == nil, let next = intervals.first else { return }
        let lead = next.start.timeIntervalSince(now)
        guard lead > 0, lead <= Self.leadTime, !notified.contains(next.start) else { return }
        notified = notified.filter { $0 > now }
        notified.insert(next.start)
        let mins = max(1, Int((lead / 60).rounded()))
        let body = "From \(formatted(next.start, "HH:mm", s.tz)): \(pence(s.cheapRate)) (now \(pence(s.peakRate)))"
        Task { await post(title: "Cheap rate in \(mins) min", body: body) }
    }

    /// Posts a notification. Returns a description of what's wrong if it couldn't be delivered.
    @discardableResult
    func post(title: String, body: String) async -> String? {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        let settingsHint = "Open System Settings → Notifications → Octopus Menu Bar and allow notifications."
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        case .denied: return "Notifications are turned off for this app. \(settingsHint)"
        default: return "macOS hasn't granted notification permission (status \(settings.authorizationStatus.rawValue)). \(settingsHint)"
        }
        if settings.alertSetting != .enabled {
            return "Alerts are disabled for this app (style is None). \(settingsHint)"
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            return "macOS refused the notification: \(error.localizedDescription)"
        }
        return nil
    }

    // Show banners even though the app is technically frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func refresh() {
        guard !loading else { return }
        guard let key = apiKey else {
            lastError = "No API key set"
            updateIcon()
            return
        }
        loading = true
        Task {
            do {
                snapshot = try await fetchSnapshot(apiKey: key)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            loading = false
            updateIcon()
            rebuildMenu()
        }
    }

    func updateIcon() {
        let symbol: String
        var color: NSColor?
        var tip: String
        if let s = snapshot, lastError == nil || Date().timeIntervalSince(s.fetched) < 900 {
            let cheap = isCheap(s, now: Date())
            symbol = cheap ? "bolt.fill" : "bolt"
            color = cheap ? .systemGreen : nil
            tip = cheap ? "Cheap rate: \(pence(s.cheapRate))" : "Standard rate: \(pence(s.peakRate))"
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        if Date().timeIntervalSince(snapshot?.fetched ?? .distantPast) > 60 { refresh() }
    }

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
        for (title, action, key) in [
            ("Refresh now", #selector(refreshNow), "r"),
            ("Alert 10 min before cheap rate", #selector(toggleNotify), ""),
            ("Send test alert", #selector(testAlert), ""),
            ("Set API Key…", #selector(setKey), ""),
            ("Quit", #selector(quit), "q"),
        ] {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            if action == #selector(toggleNotify) { mi.state = notifyEnabled ? .on : .off }
            menu.addItem(mi)
        }
    }

    @objc func refreshNow() { refresh() }

    @objc func toggleNotify() {
        UserDefaults.standard.set(!notifyEnabled, forKey: "notifyBeforeCheap")
        rebuildMenu()
    }

    @objc func testAlert() {
        Task {
            guard let problem = await post(title: "Cheap rate in 10 min", body: "This is a test alert.") else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.icon = makeAppIcon()
            alert.messageText = "Couldn't send the alert"
            alert.informativeText = problem
            alert.runModal()
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func setKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = makeAppIcon()
        alert.messageText = "Octopus API key"
        alert.informativeText = "Paste your API key (sk_live_…). It is stored in your login Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Keychain.save(value)
        apiKey = value
        snapshot = nil
        lastError = nil
        refresh()
    }
}

// MARK: - Self test (no network): OctopusMenuBar --selftest

func selfTest() {
    let tz = TimeZone(identifier: "Europe/London")!
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let snap = Snapshot(
        cheapRate: 6.5714, peakRate: 28.9251, windows: fallbackWindows,
        dispatches: [Interval(start: date("2026-09-20T12:00:00Z"), end: date("2026-09-20T13:30:00Z"), smart: true)],
        cars: [Car(name: "Mini Cooper", soc: 62, target: 100, state: "SMART_CONTROL_NOT_AVAILABLE", asOf: date("2026-09-19T14:08:36Z"))],
        tz: tz, fetched: date("2026-09-19T15:13:00Z"))
    for (label, now) in [("Sat 16:13 BST", "2026-09-19T15:13:00Z"), ("Sun 02:00 BST", "2026-09-20T01:00:00Z")] {
        print("--- \(label): cheap=\(isCheap(snap, now: date(now)))")
        for line in menuLines(snap, now: date(now)) {
            switch line {
            case .separator: print("  ------")
            case .header(let t): print("  [\(t)]")
            case .text(let t): print("  \(t)")
            }
        }
    }
}

func renderIcon(pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    makeAppIcon().draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// OctopusMenuBar --iconset DIR : write the PNGs that `iconutil -c icns` expects.
if let i = CommandLine.arguments.firstIndex(of: "--iconset"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    for size in [16, 32, 128, 256, 512] {
        renderIcon(pixels: size, to: "\(dir)/icon_\(size)x\(size).png")
        renderIcon(pixels: size * 2, to: "\(dir)/icon_\(size)x\(size)@2x.png")
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
