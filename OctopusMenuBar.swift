// Octopus Energy menu bar app: shows whether you're on the cheap or standard rate,
// your car's charge level, and the upcoming cheap-rate windows.
//
// Build: ./build.sh     Run: open build/OctopusMenuBar.app
// The API key is entered in Settings… and stored in the login Keychain.

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
    var powerKw: Double?
    var powerAsOf: Date?
    var suspended: Bool?
}

struct Snapshot {
    var cheapRate: Double
    var peakRate: Double
    var windows: [(from: Int, to: Int)]  // minutes after local midnight
    var dispatches: [Interval]
    var cars: [Car]
    var tz: TimeZone
    var fetched: Date

    /// A single-rate tariff has no cheap window, whatever the schedule says.
    var hasCheapRate: Bool { peakRate - cheapRate >= 0.01 }
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
    guard s.hasCheapRate else { return [] }
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

/// Fetch every 5 minutes, or every 30 seconds within 3 minutes either side of a rate switch.
func fetchInterval(_ s: Snapshot?, now: Date) -> TimeInterval {
    guard let s else { return 300 }
    let window: TimeInterval = 3 * 60
    // Look back one window so intervals that ended just now still count as a recent switch.
    let nearSwitch = cheapIntervals(s, now: now.addingTimeInterval(-window)).contains {
        abs($0.start.timeIntervalSince(now)) <= window || abs($0.end.timeIntervalSince(now)) <= window
    }
    return nearSwitch ? 30 : 300
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
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday"
    }
    return formatted(date, "EEE", tz)
}

func stamp(_ date: Date, now: Date, _ tz: TimeZone) -> String {
    "\(dayLabel(date, now: now, tz)) \(formatted(date, "HH:mm", tz))"
}

func pence(_ v: Double) -> String { String(format: "%.2fp/kWh", v) }

/// Octopus doesn't report "plugged in" directly, so infer charging from the live power reading
/// and the smart-control state.
func chargingStatus(_ car: Car, now: Date) -> String? {
    let state = car.state ?? ""
    let freshPower = car.powerAsOf.map { now.timeIntervalSince($0) < 20 * 60 } ?? false

    // A lost connection explains anything else we might say, so it wins.
    if state == "LOST_CONNECTION" { return "Lost connection to car" }

    // isSuspended means Octopus's smart control is paused, not that charging has stopped: a
    // suspended car left plugged in still draws power. It says nothing when control isn't available.
    let paused = car.suspended == true && state != "SMART_CONTROL_NOT_AVAILABLE"
    func annotated(_ text: String) -> String { paused ? text + " · smart control paused" : text }

    if freshPower, let kw = car.powerKw, kw > 0.05 {
        let charging = String(format: "Charging %.1f kW", kw)
        switch state {
        case "BOOSTING": return charging + " · boost"
        case "SMART_CONTROL_IN_PROGRESS": return charging + " · smart charging"
        default: return annotated(charging)
        }
    }
    switch state {
    case "BOOSTING": return "Boost charge requested"
    case "SMART_CONTROL_IN_PROGRESS": return "Smart charging scheduled"
    case "SMART_CONTROL_NOT_AVAILABLE": return "Not charging · smart control not available"
    case "SMART_CONTROL_CAPABLE", "SMART_CONTROL_OFF", "SETUP_COMPLETE", "":
        if freshPower { return annotated("Not charging") }
        return paused ? "Smart control paused" : nil
    default: return annotated(state.replacingOccurrences(of: "_", with: " ").capitalized)
    }
}

func menuLines(_ s: Snapshot, now: Date) -> [Line] {
    let tz = s.tz
    let cal = calendar(tz)
    let intervals = cheapIntervals(s, now: now)
    let active = currentInterval(intervals, now: now)
    var lines: [Line] = []

    if !s.hasCheapRate {
        lines.append(.header("Single rate · \(pence(s.peakRate))"))
        lines.append(.text("This tariff has no cheap window"))
    } else if let active {
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
            if let status = chargingStatus(car, now: now) { lines.append(.text("    " + status)) }
            if let asOf = car.asOf { lines.append(.text("    Charge level as of \(stamp(asOf, now: now, tz))")) }
        } else {
            lines.append(.text("\(car.name): no charge level reported"))
        }
    }

    guard s.hasCheapRate else {
        lines.append(.separator)
        lines.append(.text("Updated \(formatted(s.fetched, "HH:mm", tz))"))
        return lines
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

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Updates an existing item in place, or adds one. Updating rather than delete-then-add means a
    /// failure can't leave the keychain with no key at all. Returns errSecSuccess or the failure.
    static func save(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated != errSecItemNotFound { return updated }
        var item = base
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    @discardableResult
    static func delete() -> OSStatus {
        SecItemDelete(base as CFDictionary)
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
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
                status{... on SmartFlexVehicleStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
                chargingPreferences{weekdayTargetSoc weekendTargetSoc}
              }
              ... on SmartFlexChargePoint{
                status{... on SmartFlexChargePointStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
              }
            }}
            """, ["a": account], token: token)
        let weekend = calendar(tz).isDateInWeekend(now)
        for d in (dev["devices"] as? [[String: Any]]) ?? [] {
            let type = d["__typename"] as? String
            guard type == "SmartFlexVehicle" || type == "SmartFlexChargePoint" else { continue }
            let status = d["status"] as? [String: Any]
            let soc = status?["stateOfCharge"] as? [String: Any]
            let power = status?["activePower"] as? [String: Any]
            let prefs = d["chargingPreferences"] as? [String: Any]
            let label = [d["make"], d["model"]].compactMap { $0 as? String }.joined(separator: " ")
            cars.append(
                Car(
                    name: label.isEmpty ? (d["name"] as? String ?? "Vehicle") : label,
                    soc: toDouble(soc?["value"]),
                    target: (prefs?[weekend ? "weekendTargetSoc" : "weekdayTargetSoc"] as? NSNumber)?.intValue,
                    state: status?["currentState"] as? String,
                    asOf: parseDate(soc?["timestamp"]),
                    powerKw: toDouble(power?["value"]),
                    powerAsOf: parseDate(power?["timestamp"]),
                    suspended: status?["isSuspended"] as? Bool))
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
    var settingsWindow: NSWindow?
    var keyField: NSSecureTextField?
    var keyStatus: NSTextField?
    var notifyCheck: NSButton?
    /// Read from the Keychain once at launch, never while the menu is open: the system's unlock
    /// prompt can't take keyboard input while menu tracking has focus.
    var apiKey: String?
    /// When the last "cheap rate soon" alert went out, for the cooldown below.
    var lastAlertAt: Date?
    /// Dispatches get re-planned a few minutes either way, which would otherwise alert again.
    static let alertCooldown: TimeInterval = 30 * 60
    /// Consecutive failed fetches. Automatic refreshing stops at maxFailures so a bad key or a
    /// long outage can't hammer the API; "Refresh now" clears it.
    var failures = 0
    var autoRefreshPaused = false
    var menuIsOpen = false
    static let maxFailures = 10
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
        let now = Date()
        // A small tolerance stops a tick landing just short of the interval from waiting a whole extra tick.
        if now.timeIntervalSince(snapshot?.fetched ?? .distantPast) >= fetchInterval(snapshot, now: now) - 5 { refresh() }
    }

    /// Alerts once when a cheap window (fixed or smart-charge) is about to start.
    func checkUpcomingCheap() {
        guard notifyEnabled, let s = snapshot else { return }
        let now = Date()
        let intervals = cheapIntervals(s, now: now)
        guard currentInterval(intervals, now: now) == nil, let next = intervals.first else { return }
        let lead = next.start.timeIntervalSince(now)
        guard lead > 0, lead <= Self.leadTime else { return }
        if let last = lastAlertAt, now.timeIntervalSince(last) < Self.alertCooldown { return }
        lastAlertAt = now
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

    /// - Parameter manual: true for "Refresh now" and after a key change, which resumes automatic
    ///   refreshing if it has stopped.
    func refresh(manual: Bool = false) {
        guard !loading else { return }
        if manual {
            failures = 0
            autoRefreshPaused = false
        } else if autoRefreshPaused {
            return
        }
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
                failures = 0
            } catch {
                failures += 1
                if failures >= Self.maxFailures {
                    autoRefreshPaused = true
                    lastError = "\(error.localizedDescription) — stopped after \(Self.maxFailures) failed attempts. Choose Refresh now to try again."
                } else {
                    lastError = error.localizedDescription
                }
            }
            loading = false
            updateIcon()
            // No rebuildMenu() here: menuNeedsUpdate rebuilds before the menu is next displayed.
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
        for (title, action, key) in [
            ("Refresh now", #selector(refreshNow), "r"),
            ("Settings…", #selector(showSettings), ","),
            ("Quit", #selector(quit), "q"),
        ] {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            menu.addItem(mi)
        }
    }

    @objc func refreshNow() { refresh(manual: true) }

    @objc func toggleNotify(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "notifyBeforeCheap")
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

    @objc func showSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        keyField?.stringValue = ""
        setKeyStatus(apiKey == nil ? "No key saved" : "A key is saved in your Keychain", warning: false)
        notifyCheck?.state = notifyEnabled ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() {
        let heading = NSTextField(labelWithString: "Octopus API key")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let field = NSSecureTextField()
        field.placeholderString = "sk_live_…"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        save.keyEquivalent = "\r"
        let keyRow = NSStackView(views: [field, save])
        keyRow.spacing = 8

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let check = NSButton(
            checkboxWithTitle: "Alert 10 minutes before the cheap rate starts", target: self,
            action: #selector(toggleNotify(_:)))
        let test = NSButton(title: "Send Test Alert", target: self, action: #selector(testAlert))

        let stack = NSStackView(views: [heading, keyRow, status, check, test])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Pin the stack inside a container so the 20pt margin holds on every side.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        container.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: container.fittingSize), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Octopus Settings"
        window.contentView = container
        window.setContentSize(container.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
        keyField = field
        keyStatus = status
        notifyCheck = check
    }

    func setKeyStatus(_ text: String, warning: Bool) {
        keyStatus?.stringValue = text
        keyStatus?.textColor = warning ? .systemRed : .secondaryLabelColor
        // A failure message wraps onto a second line, so let the window grow to fit it.
        settingsWindow?.setContentSize(settingsWindow?.contentView?.fittingSize ?? .zero)
    }

    @objc func saveKey() {
        let value = (keyField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let status = Keychain.save(value)
        // Use the key this session even if it couldn't be stored, but say so plainly.
        apiKey = value
        keyField?.stringValue = ""
        if status == errSecSuccess {
            setKeyStatus("Key saved", warning: false)
        } else {
            setKeyStatus(
                "Couldn't save to your Keychain: \(Keychain.message(status)). The key works until you quit.",
                warning: true)
        }
        snapshot = nil
        lastError = nil
        refresh(manual: true)
    }
}

// MARK: - Self test (no network): OctopusMenuBar --selftest

func selfTest() {
    let tz = TimeZone(identifier: "Europe/London")!
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let snap = Snapshot(
        cheapRate: 6.5714, peakRate: 28.9251, windows: fallbackWindows,
        dispatches: [Interval(start: date("2026-09-20T12:00:00Z"), end: date("2026-09-20T13:30:00Z"), smart: true)],
        cars: [
            Car(name: "Mini Cooper", soc: 62, target: 100, state: "SMART_CONTROL_NOT_AVAILABLE", asOf: date("2026-09-19T14:08:36Z")),
            Car(name: "Test EV", soc: 45, target: 80, state: "SMART_CONTROL_IN_PROGRESS", asOf: date("2026-09-19T15:10:00Z"),
                powerKw: 7.2, powerAsOf: date("2026-09-19T15:10:00Z")),
        ],
        tz: tz, fetched: date("2026-09-19T15:13:00Z"))
    let then = date("2026-09-19T15:10:00Z")
    print("--- charging status")
    for (label, car) in [
        ("charging, suspended", Car(name: "", state: "SMART_CONTROL_CAPABLE", powerKw: 7.2, powerAsOf: then, suspended: true)),
        ("charging, smart", Car(name: "", state: "SMART_CONTROL_IN_PROGRESS", powerKw: 7.2, powerAsOf: then)),
        ("idle, suspended", Car(name: "", state: "SMART_CONTROL_CAPABLE", suspended: true)),
        ("idle, suspended, no control", Car(name: "", state: "SMART_CONTROL_NOT_AVAILABLE", suspended: true)),
        ("offline, suspended", Car(name: "", state: "LOST_CONNECTION", suspended: true)),
        ("idle, plugged in", Car(name: "", state: "SMART_CONTROL_CAPABLE", powerKw: 0, powerAsOf: then)),
        ("nothing known", Car(name: "")),
    ] {
        print("  \(label): \(chargingStatus(car, now: date("2026-09-19T15:13:00Z")) ?? "(no line)")")
    }

    var flat = snap
    flat.cheapRate = flat.peakRate
    for (label, now, s) in [
        ("Sat 16:13 BST", "2026-09-19T15:13:00Z", snap),
        ("Sun 02:00 BST", "2026-09-20T01:00:00Z", snap),
        ("flat tariff", "2026-09-20T01:00:00Z", flat),
    ] {
        print("--- \(label): cheap=\(isCheap(s, now: date(now)))")
        for line in menuLines(s, now: date(now)) {
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
