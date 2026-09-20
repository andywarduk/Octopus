// "Cheap rate soon" alerts, and the test alert in Settings.

import Cocoa
import UserNotifications

extension AppDelegate {
    /// Alerts once when a cheap window (fixed or smart-charge) is about to start.
    func checkUpcomingCheap(intervals: [Interval]) {
        guard notifyEnabled, let s = snapshot else { return }
        let now = Date()
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
}
