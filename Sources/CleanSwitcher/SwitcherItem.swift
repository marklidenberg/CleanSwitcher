import Cocoa

/// One tile in the switcher panel — an app tile (Cmd+Tab) carries an `AppInfo`,
/// a window tile (Cmd+`) carries a `WindowInfo`. The panel is written against
/// this so it never branches on mode.
struct SwitcherItem {
    let icon: NSImage
    let badge: String?

    /// App name (app mode) or window title (window mode). Shown in the panel's
    /// label only in window mode; app mode renders icons alone.
    let title: String

    let appInfo: AppInfo?
    let window: WindowInfo?

    static func app(_ app: AppInfo) -> SwitcherItem {
        SwitcherItem(icon: app.icon, badge: app.badge, title: app.name, appInfo: app, window: nil)
    }

    static func window(_ window: WindowInfo) -> SwitcherItem {
        SwitcherItem(icon: window.icon, badge: nil, title: window.title, appInfo: nil, window: window)
    }

    /// Identity for append-diffing the live app list.
    var identityPID: pid_t { appInfo?.pid ?? window?.pid ?? -1 }
}
