import Cocoa

/// Persisted settings, wrapping `UserDefaults.standard`. All keys live here.
enum Preferences {

    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let mainRowTTLMinutes = "mainRowTTLMinutes"
        static let appSwitcherMode = "appSwitcherMode"
        static let windowSwitcherMode = "windowSwitcherMode"
        static let appSwitcherShortcut = "appSwitcherShortcut"
        static let windowSwitcherShortcut = "windowSwitcherShortcut"
        static let raiseAllWindows = "raiseAllWindows"
        static let maximizeNewWindows = "maximizeNewWindows"
        static let hideOtherAppsOnSwitch = "hideOtherAppsOnSwitch"
        static let appsShortcut = "bubblesShortcut"  // the stored names kept, so the settings carry over
        static let appsEnabled = "bubblesEnabled"
        static let appsState = "bubblesState"
        static let moveCursorOnOpen = "moveCursorOnOpen"
        static let appsOpenOnRest = "appsOpenOnRest"
        static let appsRestDelay = "appsRestDelay"
        static let appsLetters = "appsLetters"
        static let appsHoverStyle = "appsHoverStyle"
        static let appsUnmatchedOpacity = "appsUnmatchedOpacity"
        static let appsRecentRunningOnly = "appsRecentRunningOnly"
        static let appsLettersRecent = "appsLettersRecent"
        static let appsLettersPause = "appsLettersPause"
        static let appsShape = "appsShape"
        static let appsSeparator = "appsSeparator"
        static let appsPinnedSize = "appsPinnedSize"
        static let appsRecentSize = "appsRecentSize"
        static let appsGap = "appsGap"
        static let appsPadding = "appsPadding"
        static let appsPosition = "appsPosition"
        static let appsNearCursor = "appsNearCursor"
        static let appSwitcherGesture = "appSwitcherSwipe"
        static let windowSwitcherGesture = "windowSwitcherSwipe"
        static let appsGesture = "appsSwipe"
    }

    private static let defaults = UserDefaults.standard

    /// In-process fallbacks. Doesn't persist, so run before any read, every launch.
    static func registerDefaults() {
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.mainRowTTLMinutes: 60,
            Key.appsEnabled: true,
            Key.moveCursorOnOpen: true,
            Key.appsOpenOnRest: true,
            Key.appsRestDelay: 200,
            Key.appsLetters: LettersMode.off.rawValue,
            Key.appsHoverStyle: HoverStyle.backdrop.rawValue,
            Key.appsUnmatchedOpacity: 15,
            Key.appsLettersPause: 400,
            Key.appsLettersRecent: true,
            Key.appsShape: "pill",
            Key.appsSeparator: false,
            Key.appsPinnedSize: 64,
            Key.appsRecentSize: 64,
            Key.appsGap: 2,
            Key.appsPadding: 12,
            Key.appsPosition: 42,
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

    static var appSwitcherShortcut: Shortcut {
        get { shortcut(forKey: Key.appSwitcherShortcut) ?? .defaultAppSwitcher }
        set { defaults.set([newValue.keyCode, Int(newValue.modifiers.rawValue)], forKey: Key.appSwitcherShortcut) }
    }

    static var windowSwitcherShortcut: Shortcut {
        get { shortcut(forKey: Key.windowSwitcherShortcut) ?? .defaultWindowSwitcher }
        set { defaults.set([newValue.keyCode, Int(newValue.modifiers.rawValue)], forKey: Key.windowSwitcherShortcut) }
    }

    /// Stored as `[keyCode, modifierFlags]`.
    private static func shortcut(forKey key: String) -> Shortcut? {
        guard let pair = defaults.array(forKey: key) as? [Int], pair.count == 2 else { return nil }
        return Shortcut(keyCode: pair[0], modifiers: NSEvent.ModifierFlags(rawValue: UInt(pair[1])))
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

    /// Opens the Apps panel: a combo, or a lone modifier tapped.
    static var appsShortcut: Shortcut {
        get { shortcut(forKey: Key.appsShortcut) ?? .defaultApps }
        set { defaults.set([newValue.keyCode, Int(newValue.modifiers.rawValue)], forKey: Key.appsShortcut) }
    }

    static var appsEnabled: Bool {
        get { defaults.bool(forKey: Key.appsEnabled) }
        set { defaults.set(newValue, forKey: Key.appsEnabled) }
    }

    /// The Apps panel's state (`AppsStore`), JSON.
    static var appsState: Data? {
        get { defaults.data(forKey: Key.appsState) }
        set { defaults.set(newValue, forKey: Key.appsState) }
    }

    /// On open, the cursor goes to the pinned apps, on the optical center.
    static var moveCursorOnOpen: Bool {
        get { defaults.bool(forKey: Key.moveCursorOnOpen) }
        set { defaults.set(newValue, forKey: Key.moveCursorOnOpen) }
    }

    /// The cursor stopped on an icon opens its app.
    static var appsOpenOnRest: Bool {
        get { defaults.bool(forKey: Key.appsOpenOnRest) }
        set { defaults.set(newValue, forKey: Key.appsOpenOnRest) }
    }

    /// The Apps panel's letters: each icon's in a chip; typed — the app opens.
    enum LettersMode: String, CaseIterable {
        case off
        case pause    // an app's letters, then a pause — it opens; a key more — the search
        case instant  // an app's letters — it opens; no search
    }

    /// An icon under the cursor: as is, on a plate (like Cmd+Tab's), or glowing.
    enum HoverStyle: String, CaseIterable { case none, backdrop, glow }

    static var appsHoverStyle: HoverStyle {
        get { HoverStyle(rawValue: defaults.string(forKey: Key.appsHoverStyle) ?? "") ?? .backdrop }
        set { defaults.set(newValue.rawValue, forKey: Key.appsHoverStyle) }
    }

    /// The icons whose letters don't match what's typed: this % opaque.
    static var appsUnmatchedOpacity: Int {
        get { defaults.integer(forKey: Key.appsUnmatchedOpacity) }
        set { defaults.set(newValue, forKey: Key.appsUnmatchedOpacity) }
    }

    /// An app gone from recent once it quits, not at the TTL.
    static var appsRecentRunningOnly: Bool {
        get { defaults.bool(forKey: Key.appsRecentRunningOnly) }
        set { defaults.set(newValue, forKey: Key.appsRecentRunningOnly) }
    }

    static var appsLetters: LettersMode {
        get { LettersMode(rawValue: defaults.string(forKey: Key.appsLetters) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.appsLetters) }
    }

    /// Letters on the recent too — after the pinned's, longer where they clash.
    static var appsLettersRecent: Bool {
        get { defaults.bool(forKey: Key.appsLettersRecent) }
        set { defaults.set(newValue, forKey: Key.appsLettersRecent) }
    }

    /// The pause, in ms, after an app's letters before it opens.
    static var appsLettersPause: Int {
        get { defaults.integer(forKey: Key.appsLettersPause) }
        set { defaults.set(newValue, forKey: Key.appsLettersPause) }
    }

    /// How long, in ms, the cursor stays still on an icon before it opens.
    static var appsRestDelay: Int {
        get { defaults.integer(forKey: Key.appsRestDelay) }
        set { defaults.set(newValue, forKey: Key.appsRestDelay) }
    }

    /// The Apps panel's look: "pill" or "box"; a line between pinned and recent or not;
    /// the pinned and the recent icons' sizes, the gap, the padding — points.
    static var appsShape: String {
        get { defaults.string(forKey: Key.appsShape) ?? "pill" }
        set { defaults.set(newValue, forKey: Key.appsShape) }
    }

    static var appsSeparator: Bool {
        get { defaults.bool(forKey: Key.appsSeparator) }
        set { defaults.set(newValue, forKey: Key.appsSeparator) }
    }

    static var appsPinnedSize: Int {
        get { defaults.integer(forKey: Key.appsPinnedSize) }
        set { defaults.set(newValue, forKey: Key.appsPinnedSize) }
    }

    static var appsRecentSize: Int {
        get { defaults.integer(forKey: Key.appsRecentSize) }
        set { defaults.set(newValue, forKey: Key.appsRecentSize) }
    }

    static var appsGap: Int {
        get { defaults.integer(forKey: Key.appsGap) }
        set { defaults.set(newValue, forKey: Key.appsGap) }
    }

    /// Where the box's middle sits, % down the screen — 42: the optical center, a bit above the middle.
    static var appsPosition: Int {
        get { defaults.integer(forKey: Key.appsPosition) }
        set { defaults.set(newValue, forKey: Key.appsPosition) }
    }

    /// The box opens around the cursor, not at `appsPosition`.
    static var appsNearCursor: Bool {
        get { defaults.bool(forKey: Key.appsNearCursor) }
        set { defaults.set(newValue, forKey: Key.appsNearCursor) }
    }

    static var appsPadding: Int {
        get { defaults.integer(forKey: Key.appsPadding) }
        set { defaults.set(newValue, forKey: Key.appsPadding) }
    }

    /// A trackpad swipe per command, nil — none.
    static var appSwitcherGesture: Gesture? {
        get { defaults.string(forKey: Key.appSwitcherGesture).flatMap(Gesture.init(code:)) }
        set { defaults.set(newValue?.code, forKey: Key.appSwitcherGesture) }
    }

    static var windowSwitcherGesture: Gesture? {
        get { defaults.string(forKey: Key.windowSwitcherGesture).flatMap(Gesture.init(code:)) }
        set { defaults.set(newValue?.code, forKey: Key.windowSwitcherGesture) }
    }

    static var appsGesture: Gesture? {
        get { defaults.string(forKey: Key.appsGesture).flatMap(Gesture.init(code:)) }
        set { defaults.set(newValue?.code, forKey: Key.appsGesture) }
    }

    static var mainRowTTL: TimeInterval { TimeInterval(mainRowTTLMinutes) * 60 }
}
