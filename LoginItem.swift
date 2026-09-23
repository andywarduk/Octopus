// Starting at login, via the modern ServiceManagement API.
//
// SMAppService registers the app bundle itself rather than writing a launch agent plist, so there
// is nothing to clean up if the app is deleted, and macOS shows it under Login Items where the
// user can override whatever the app asks for.

import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Approval-pending counts as on: the user has asked for it, and macOS is the one hesitating.
    static var isEnabled: Bool {
        let current = status
        return current == .enabled || current == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            // Unregistering something already absent throws, which is not a failure worth
            // reporting to anyone.
            guard status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// What to tell the user, or nil when there is nothing they need to do.
    ///
    /// Pure, so `--selftest` can cover the wording without touching the real login items.
    static func advice(for status: SMAppService.Status) -> String? {
        switch status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "macOS needs you to allow it in System Settings → General → Login Items."
        case .notFound:
            // Registering from a build folder tends to land here: the bundle is not where
            // LaunchServices expects an installed app to be.
            return "macOS can't find the app bundle. Install it with ./install.sh and try again."
        case .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        case .notRegistered: return "not registered"
        @unknown default: return "unknown"
        }
    }
}
