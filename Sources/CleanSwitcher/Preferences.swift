import Cocoa

/// Persisted settings, wrapping `UserDefaults.standard`. All keys live here.
enum Preferences {

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let mainRowTTLMinutes = "mainRowTTLMinutes"
        static let appSwitcherMode = "appSwitcherMode"
        static let windowSwitcherMode = "windowSwitcherMode"
        static let raiseAllWindows = "raiseAllWindows"
        static let maximizeNewWindows = "maximizeNewWindows"
        static let hideOtherAppsOnSwitch = "hideOtherAppsOnSwitch"
    }

    private static let defaults = UserDefaults.standard

    /// In-process fallbacks. Doesn't persist, so run before any read, every launch.
    static func registerDefaults() {
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.mainRowTTLMinutes: 60,
        ])
    }

    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// How recently an app/window must have been focused to sit in the main row.
    static var mainRowTTLMinutes: Int {
        get { defaults.integer(forKey: Key.mainRowTTLMinutes) }
        set { defaults.set(newValue, forKey: Key.mainRowTTLMinutes) }
    }

    /// What a hotkey does from idle:
    /// - normal: open the switcher panel
    /// - recentOnly: switch straight to the previous app/window, no panel
    /// - disabled: nothing (still swallowed, native one stays off)
    enum HotkeyMode: String, CaseIterable {
        case normal, recentOnly, disabled
    }

    /// Cmd+Tab
    static var appSwitcherMode: HotkeyMode {
        get { defaults.string(forKey: Key.appSwitcherMode).flatMap(HotkeyMode.init) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.appSwitcherMode) }
    }

    /// Cmd+`
    static var windowSwitcherMode: HotkeyMode {
        get { defaults.string(forKey: Key.windowSwitcherMode).flatMap(HotkeyMode.init) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.windowSwitcherMode) }
    }

    /// Any app activation (Spotlight, Dock, click, switcher) brings all its windows forward.
    static var raiseAllWindows: Bool {
        get { defaults.bool(forKey: Key.raiseAllWindows) }
        set { defaults.set(newValue, forKey: Key.raiseAllWindows) }
    }

    /// New standard windows of any app open filling their screen.
    static var maximizeNewWindows: Bool {
        get { defaults.bool(forKey: Key.maximizeNewWindows) }
        set { defaults.set(newValue, forKey: Key.maximizeNewWindows) }
    }

    /// Any app activation hides all other apps (like Cmd+Opt+H).
    static var hideOtherAppsOnSwitch: Bool {
        get { defaults.bool(forKey: Key.hideOtherAppsOnSwitch) }
        set { defaults.set(newValue, forKey: Key.hideOtherAppsOnSwitch) }
    }

    static var mainRowTTL: TimeInterval { TimeInterval(mainRowTTLMinutes) * 60 }
}
