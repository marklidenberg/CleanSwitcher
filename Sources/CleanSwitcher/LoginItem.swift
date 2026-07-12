import Foundation
import ServiceManagement

/// "Start at login" via `SMAppService` (macOS 13+). The system is the source of
/// truth for the on/off state. On older macOS the feature is unsupported.
enum LoginItem {

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Enable launch-at-login once, on first ever run. A UserDefaults flag keeps a
    /// later opt-out from being silently re-enabled on the next launch.
    static func enableByDefaultOnFirstRun() {
        let key = "didApplyDefaultLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            NSLog("CleanSwitcher: failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            return false
        }
    }
}
