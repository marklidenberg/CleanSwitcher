import Cocoa

/// Single source of truth for persisted settings, wrapping `UserDefaults.standard`.
/// All keys live here so nothing is referenced as a stray string literal.
enum Preferences {

    // MARK: - Keys

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let mainRowTTLMinutes = "mainRowTTLMinutes"
    }

    private static let defaults = UserDefaults.standard

    /// Registers in-process fallbacks. Does NOT persist, so this must run before
    /// any read, on every launch (see AppDelegate.applicationDidFinishLaunching).
    static func registerDefaults() {
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.mainRowTTLMinutes: 60,
        ])
    }

    // MARK: - Accessors

    static var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// How recently an app must have been focused to appear in the app switcher,
    /// and to sit in a window switcher's main section. Stored in minutes for a
    /// friendly Preferences control. Defaults to 60 (see registerDefaults).
    static var mainRowTTLMinutes: Int {
        get { defaults.integer(forKey: Key.mainRowTTLMinutes) }
        set { defaults.set(newValue, forKey: Key.mainRowTTLMinutes) }
    }

    /// The main-row TTL as a `TimeInterval` (seconds), for the split logic.
    static var mainRowTTL: TimeInterval { TimeInterval(mainRowTTLMinutes) * 60 }
}
