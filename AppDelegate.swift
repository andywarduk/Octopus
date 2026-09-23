// The app's controller: owns the status item, the fetch/refresh cycle and the 30-second tick.
// Its menu, notification and settings-window code live in the AppDelegate+… files alongside.

import Cocoa
import UserNotifications

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
    var dispatchCheck_: NSButton?
    var tariffCheck: NSButton?
    var loginCheck: NSButton?
    var removeButton: NSButton?
    lazy var usageControllers: [Fuel: UsageWindowController] = Dictionary(
        uniqueKeysWithValues: Fuel.allCases.map {
            ($0, UsageWindowController(fuel: $0, apiKey: { [weak self] in self?.apiKey }))
        })
    /// One window, with the source switchable inside it. Both sources answer regionally, so the
    /// postcode comes from whichever property's electricity meter is selected.
    lazy var carbonController = CarbonWindowController(
        apiKey: { [weak self] in self?.apiKey },
        postcode: { [weak self] in
            MeterPreference.resolve(from: self?.meterChoices ?? [], fuel: .electricity)?.postcode
        })
    var meterPickers: [Fuel: NSPopUpButton] = [:]
    var meterChoices: [MeterChoice] = []
    /// Read from the Keychain once at launch, never while the menu is open: the system's unlock
    /// prompt can't take keyboard input while menu tracking has focus.
    var apiKey: String?
    /// When the last "cheap rate soon" alert went out, for the cooldown below.
    var lastAlertAt: Date?
    /// Dispatches get re-planned a few minutes either way, which would otherwise alert again.
    static let alertCooldown: TimeInterval = 30 * 60
    /// When the last "plan changed" alert went out. A plan that flaps between two shapes would
    /// otherwise alert on every flip.
    var lastDispatchAlertAt: Date?
    static let dispatchCooldown: TimeInterval = 10 * 60
    var dispatchAlertEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifyDispatchChange") as? Bool ?? true
    }
    var tariffAlertEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifyTariffEnding") as? Bool ?? true
    }
    /// The tightest threshold already announced per agreement. Persisted, because the alert is
    /// once per threshold over two months and a relaunch must not start that over.
    var tariffAlerted: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "tariffAlerted") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "tariffAlerted") }
    }
    /// Consecutive failed fetches. Automatic refreshing stops at maxFailures so a bad key or a
    /// long outage can't hammer the API; "Refresh Now" clears it.
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
        // Needed by the menu, so don't wait for Settings to be opened.
        loadMeterChoices()
        // .common, not the default mode: while the menu is open the run loop is tracking events,
        // and a default-mode timer wouldn't fire until it closed.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)

        // Timers don't fire while the Mac is asleep, so catch up rather than wait out the interval.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        let now = Date()
        // One pass per tick: everything below works from these. The lookback keeps intervals that
        // ended moments ago, which fetchInterval needs to spot a switch that has just happened.
        let recent = snapshot.map { cheapIntervals($0, now: now.addingTimeInterval(-switchWindow)) } ?? []
        let current = recent.filter { $0.end > now }
        updateIcon(intervals: current)
        checkUpcomingCheap(intervals: current)
        // A small tolerance stops a tick landing just short of the interval from waiting a whole extra tick.
        if now.timeIntervalSince(snapshot?.fetched ?? .distantPast) >= fetchInterval(recent, now: now) - 5 { refresh() }
    }

    /// - Parameter manual: true for "Refresh Now" and after a key change, which resumes automatic
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
                // Keep the old plan to compare against; nil on the first fetch, which must not alert.
                let previous = snapshot
                snapshot = try await fetchSnapshot(apiKey: key)
                lastError = nil
                failures = 0
                if let current = snapshot {
                    if let previous { checkDispatchChange(from: previous, to: current) }
                    // Unlike a dispatch change this needs no comparison, so it runs on the first
                    // fetch too — an expiry a fortnight away shouldn't wait for a second refresh.
                    checkTariffEnding(current)
                }
            } catch {
                failures += 1
                if failures >= Self.maxFailures {
                    autoRefreshPaused = true
                    lastError = "\(error.localizedDescription) — stopped after \(Self.maxFailures) failed attempts. Choose Refresh Now to try again."
                } else {
                    lastError = error.localizedDescription
                }
            }
            loading = false
            updateIcon()
            // No rebuildMenu() here: menuNeedsUpdate rebuilds before the menu is next displayed.
        }
    }


    /// Unknown until discovery runs, and an unknown fuel is shown rather than hidden.
    func hasMeters(_ fuel: Fuel) -> Bool {
        meterChoices.isEmpty || meterChoices.contains { $0.fuel == fuel }
    }

    @objc func showUsage() { usageControllers[.electricity]?.show() }

    @objc func showGasUsage() { usageControllers[.gas]?.show() }

    @objc func showCarbon() { carbonController.show() }

    @objc func refreshNow() { refresh(manual: true) }

    @objc func quit() { NSApp.terminate(nil) }
}
