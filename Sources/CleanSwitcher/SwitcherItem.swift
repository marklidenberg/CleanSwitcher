import Cocoa

/// A single tile in the switcher panel. Backs both modes: an app tile (Cmd+Tab)
/// carries an `AppInfo`; a window tile (Cmd+`) carries a `WindowInfo`. The panel
/// and AppItemView are written against this so they don't branch on mode.
struct SwitcherItem {
    let icon: NSImage
    let badge: String?
    /// App name (app mode) or window title (window mode). Shown in the panel's
    /// title label only in window mode; app mode renders icons alone.
    let title: String
    let appInfo: AppInfo?
    let window: WindowInfo?

    static func app(_ app: AppInfo) -> SwitcherItem {
        SwitcherItem(icon: app.icon, badge: app.badge, title: app.name, appInfo: app, window: nil)
    }

    static func window(_ window: WindowInfo) -> SwitcherItem {
        SwitcherItem(icon: window.icon, badge: nil, title: window.title, appInfo: nil, window: window)
    }

    /// Stable-enough identity for append-diffing the live app list.
    var identityPID: pid_t { appInfo?.pid ?? window?.pid ?? -1 }
}
