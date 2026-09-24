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
    /// The boundary the last rate-change alert was about — not when it was sent. See
    /// checkRateChange for why that distinction matters.
    var lastAlertedChange: Date?
    /// How far a boundary may move and still count as the same switch.
    static let changeTolerance: TimeInterval = 5 * 60
    /// The cooldown on "plan changed" alerts, and the plan held while it runs.
    var dispatchGate = DispatchAlertGate()
    /// Bumped whenever what a fetch would show changes underneath it — a new key, another meter,
    /// the key removed. A fetch that started before the bump is discarded when it lands.
    var fetchGeneration = 0
    /// A manual refresh asked for while one was already running. It runs as soon as that one ends,
    /// rather than being dropped and leaving the old key's or old meter's data up for five minutes.
    var refreshQueued = false
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
    /// What the status item last showed, so a tick that changes nothing doesn't redraw it.
    var shownIcon: String?
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
        // Lets macOS fold the wakeup in with others rather than waking just for this. A tick can
        // only land late, never early, and nothing here needs better than a few seconds.
        timer.tolerance = 3
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
        checkRateChange(intervals: current)
        // A small tolerance stops a tick landing just short of the interval from waiting a whole extra tick.
        if now.timeIntervalSince(snapshot?.fetched ?? .distantPast) >= fetchInterval(recent, now: now) - 5 { refresh() }
    }

    /// - Parameter manual: true for "Refresh Now" and after a key change, which resumes automatic
    ///   refreshing if it has stopped.
    func refresh(manual: Bool = false) {
        guard !loading else {
            if manual { refreshQueued = true }
            return
        }
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
        let generation = fetchGeneration
        Task {
            do {
                let fetched = try await fetchSnapshot(apiKey: key, force: manual)
                // Started under another key or meter: its answer is to a question nobody is asking.
                if generation == fetchGeneration {
                    // The old plan to compare against, taken now rather than when the fetch began
                    // so an invalidation in between leaves nothing to compare. Nil on the first
                    // fetch, which must not alert.
                    let previous = snapshot
                    let current = carryForwardDevices(fetched, from: previous, now: Date())
                    snapshot = current
                    lastError = nil
                    failures = 0
                    if let previous { checkDispatchChange(from: previous, to: current) }
                    // Unlike a dispatch change this needs no comparison, so it runs on the first
                    // fetch too — an expiry a fortnight away shouldn't wait for a second refresh.
                    checkTariffEnding(current)
                }
            } catch {
                await invalidateSession(after: error)
                if generation == fetchGeneration {
                    failures += 1
                    if failures >= Self.maxFailures {
                        autoRefreshPaused = true
                        lastError = "\(error.localizedDescription) — stopped after \(Self.maxFailures) failed attempts. Choose Refresh Now to try again."
                    } else {
                        lastError = error.localizedDescription
                    }
                }
            }
            loading = false
            updateIcon()
            // No rebuildMenu() here: menuNeedsUpdate rebuilds before the menu is next displayed.
            if refreshQueued {
                refreshQueued = false
                refresh(manual: true)
            }
        }
    }

    /// What is on screen no longer applies — the key or the meter changed. Drops it, and makes
    /// sure a fetch already under way for the old one can't put it back.
    func invalidateSnapshot() {
        snapshot = nil
        fetchGeneration += 1
        dispatchGate.held = nil
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
