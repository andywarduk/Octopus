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
    var removeButton: NSButton?
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


    @objc func refreshNow() { refresh(manual: true) }

    @objc func quit() { NSApp.terminate(nil) }
}
