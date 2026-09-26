import Cocoa

/// Persisted settings, wrapping `UserDefaults.standard`. All keys live here.
enum Preferences {

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let mainRowTTLMinutes = "mainRowTTLMinutes"
        static let disableAppSwitcher = "disableAppSwitcher"
        static let disableWindowSwitcher = "disableWindowSwitcher"
        static let raiseAllWindows = "raiseAllWindows"
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

    /// Cmd+Tab is swallowed (no-op) instead of opening the app switcher.
    static var disableAppSwitcher: Bool {
        get { defaults.bool(forKey: Key.disableAppSwitcher) }
        set { defaults.set(newValue, forKey: Key.disableAppSwitcher) }
    }

    /// Cmd+` is swallowed (no-op) instead of opening the window switcher.
    static var disableWindowSwitcher: Bool {
        get { defaults.bool(forKey: Key.disableWindowSwitcher) }
        set { defaults.set(newValue, forKey: Key.disableWindowSwitcher) }
    }

    /// Any app activation (Spotlight, Dock, click, switcher) brings all its windows forward.
    static var raiseAllWindows: Bool {
        get { defaults.bool(forKey: Key.raiseAllWindows) }
        set { defaults.set(newValue, forKey: Key.raiseAllWindows) }
    }

    static var mainRowTTL: TimeInterval { TimeInterval(mainRowTTLMinutes) * 60 }
}
