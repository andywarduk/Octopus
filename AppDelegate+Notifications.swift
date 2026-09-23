// Rate-change, smart-charge and tariff-end alerts, plus the test alert in Settings.

import Cocoa
import UserNotifications

extension AppDelegate {
    /// Alerts once before the rate changes, in either direction — cheap starting or cheap ending.
    func checkRateChange(intervals: [Interval]) {
        guard notifyEnabled, let s = snapshot, s.hasCheapRate else { return }
        let now = Date()
        guard let change = nextRateChange(intervals, now: now) else { return }
        let lead = change.at.timeIntervalSince(now)
        guard lead > 0, lead <= Self.leadTime else { return }
        // Keyed to the boundary rather than to when the last alert was sent. Octopus nudges
        // dispatch times by a minute or two, so a plain cooldown either re-alerted for the same
        // switch or, on a short dispatch, silenced the end of one because the start was recent.
        if let last = lastAlertedChange,
            abs(change.at.timeIntervalSince(last)) <= Self.changeTolerance
        { return }
        lastAlertedChange = change.at

        let mins = max(1, Int((lead / 60).rounded()))
        let (from, to) = change.toCheap ? (s.peakRate, s.cheapRate) : (s.cheapRate, s.peakRate)
        let title = change.toCheap ? "Cheap rate in \(mins) min" : "Standard rate in \(mins) min"
        let body = "From \(formatted(change.at, "HH:mm", s.tz)): \(pence(to)) (now \(pence(from)))"
        Task { await post(title: title, body: body) }
    }

    /// Alerts when the smart-charge plan gains or loses a slot.
    func checkDispatchChange(from previous: Snapshot, to current: Snapshot) {
        guard dispatchAlertEnabled else { return }
        let now = Date()
        if let last = lastDispatchAlertAt, now.timeIntervalSince(last) < Self.dispatchCooldown { return }
        guard
            let change = dispatchChange(
                from: futureDispatches(previous, now: now), to: futureDispatches(current, now: now),
                tz: current.tz)
        else { return }
        lastDispatchAlertAt = now
        Task { await post(title: change.title, body: change.body) }
    }

    /// Alerts as a fixed tariff's end approaches: once at 30 days, then 14, 7 and the day before.
    /// Which thresholds have been announced is remembered across launches, so restarting the app
    /// doesn't repeat them.
    func checkTariffEnding(_ s: Snapshot) {
        guard tariffAlertEnabled else { return }
        let now = Date()
        var alerted = tariffAlerted
        for end in endingSoon(s.tariffEnds, now: now, tz: s.tz) {
            guard let ending = end.ends else { continue }
            let last = lastCoveredDay(ending, s.tz)
            let days = daysUntil(last, now: now, s.tz)
            // Keyed without the property: the list shows both houses, but being told twice that
            // the same tariff ends on the same day is noise.
            guard let threshold = tariffAlertThreshold(daysLeft: days, alerted: alerted[end.alertKey])
            else { continue }
            alerted[end.alertKey] = threshold
            let at = s.propertyCount > 1 && !end.property.isEmpty ? " at \(end.property)" : ""
            let body = "Your \(end.fuel.rawValue) tariff\(at) runs until "
                + "\(formatted(last, "EEEE d MMMM", s.tz))."
                + " Check your Octopus account to choose what happens next."
            Task { await post(title: "\(end.name) ends \(dayCount(days))", body: body) }
        }
        // Drop agreements that are gone, so the record doesn't grow without limit. Only when
        // something came back: an empty list after a bad fetch would wipe the history and
        // re-alert everything next time.
        if !s.tariffEnds.isEmpty {
            let live = Set(s.tariffEnds.map(\.alertKey))
            alerted = alerted.filter { live.contains($0.key) }
        }
        tariffAlerted = alerted
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

    @objc func testAlert() {
        Task {
            guard let problem = await post(title: "Rate changes in 10 min", body: "This is a test alert.") else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.icon = makeAppIcon()
            alert.messageText = "Couldn't send the alert"
            alert.informativeText = problem
            alert.runModal()
        }
    }
}
