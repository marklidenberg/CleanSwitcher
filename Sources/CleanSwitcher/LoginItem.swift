import Foundation
import ServiceManagement

/// "Start at login" via `SMAppService` (macOS 13+). The system is the source of
/// truth for the on/off state — there is no UserDefaults key. On older macOS the
/// feature is unsupported and the Preferences checkbox is hidden.
enum LoginItem {

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Enable launch-at-login once, on first ever run. Guarded by a UserDefaults
    /// flag so a later user opt-out isn't silently re-enabled on the next launch.
    static func enableByDefaultOnFirstRun() {
        let key = "didApplyDefaultLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }

    /// Whether CleanSwitcher is currently registered to launch at login.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Registers/unregisters the app as a login item. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("CleanSwitcher: failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            return false
        }
    }
}
